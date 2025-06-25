create database gift_card_platform;
use gift_card_platform;

                                                       #User table
CREATE TABLE users (
    user_id INT unique AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

                                                     #Gift card table
CREATE TABLE gift_cards (
    card_id CHAR(7) PRIMARY KEY,           
    initial_balance DECIMAL(10,2) NOT NULL,
    current_balance DECIMAL(10,2) NOT NULL,
    expiration_date DATE NOT NULL,
    status ENUM('active', 'inactive', 'blocked', 'expired') DEFAULT 'active',
    user_id INT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_user FOREIGN KEY (user_id) 
        REFERENCES users(user_id) 
        ON DELETE SET NULL,
    CHECK (current_balance >= 0)
);


                                        #transaction table for redemption,recharge,transfer

CREATE TABLE gift_card_transactions (
    transaction_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    card_id CHAR(7),  -- FK removed or made nullable with SET NULL
    user_id INT NULL,
    transaction_type ENUM('redemption', 'recharge', 'transfer_out', 'transfer_in') NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    transaction_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    notes VARCHAR(255),
    CONSTRAINT fk_user_tx FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE SET NULL
);


                                        #Gift card generate for single & Bulk

DELIMITER //

# first we create a function to help us generate cards in bulk & single
-- Function to generate unique card_id (random alphanumeric 7 chars)
CREATE FUNCTION generate_card_id()
RETURNS CHAR(7)
DETERMINISTIC
BEGIN
    DECLARE card CHAR(7);
    DECLARE done INT DEFAULT 0;

    REPEAT
        SET card = SUBSTRING(MD5(RAND()), 1, 7);
        -- Check if card exists
        IF (SELECT COUNT(*) FROM gift_cards WHERE card_id = card) = 0 THEN
            SET done = 1;
        END IF;
    UNTIL done = 1 END REPEAT;

    RETURN card;
END //

										#Generate single card 

-- Generate single gift card
CREATE PROCEDURE generate_gift_card (
    IN init_balance DECIMAL(10,2),
    IN expiry DATE,
    IN associated_user INT,
    OUT out_card_id CHAR(7)
)
BEGIN
    DECLARE new_card CHAR(7);
    SET new_card = generate_card_id();

    INSERT INTO gift_cards(card_id, initial_balance, current_balance, expiration_date, user_id)
    VALUES (new_card, init_balance, init_balance, expiry, associated_user);

    SET out_card_id = new_card;
END //

                                                   #Bulk Gift Card Generate
-- Bulk gift card generation
DELIMITER //

CREATE PROCEDURE bulk_generate_gift_cards (
    IN count INT,
    IN init_balance DECIMAL(10,2),
    IN expiry DATE,
    IN associated_user INT
)
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE new_card CHAR(7);

    -- Validate input parameters
    IF count <= 0 THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Count must be a positive integer';
    END IF;
    
    IF init_balance <= 0 THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Initial balance must be positive';
    END IF;
    
    IF expiry <= CURDATE() THEN
        SIGNAL SQLSTATE '45000' 
        SET MESSAGE_TEXT = 'Expiration date must be in the future';
    END IF;

    -- Start transaction for bulk operation
    START TRANSACTION;
    
    -- Generate the specified number of gift cards
    WHILE i < count DO
        SET new_card = generate_card_id();
        
        -- Insert with explicit 'inactive' status
        INSERT INTO gift_cards(
            card_id, 
            initial_balance, 
            current_balance, 
            expiration_date, 
            user_id,
            status
        )
        VALUES (
            new_card, 
            init_balance, 
            init_balance, 
            expiry, 
            associated_user,
            'inactive'  -- Explicitly set status to inactive
        );
        
        SET i = i + 1;
    END WHILE;
    
    COMMIT;
    
    -- Return success message
    SELECT CONCAT('Successfully generated ', count, ' inactive gift cards') AS message;
END //

DELIMITER ;
                                               #Redemption and Fraud Detection

DELIMITER //

CREATE PROCEDURE redeem_gift_card (
    IN p_card_id CHAR(7),
    IN p_user_id INT,
    IN p_amount DECIMAL(10,2),
    OUT p_success BOOLEAN,
    OUT p_message VARCHAR(255)
)
BEGIN
    DECLARE v_balance DECIMAL(10,2);
    DECLARE v_status ENUM('active', 'inactive', 'blocked', 'expired');
    DECLARE v_expired BOOL;
    DECLARE v_user_id INT;

    proc_end: BEGIN
        -- Card existence and lock the row for concurrency safety
        SELECT current_balance, status, (expiration_date < CURDATE()), user_id
        INTO v_balance, v_status, v_expired, v_user_id
        FROM gift_cards
        WHERE card_id = p_card_id
        FOR UPDATE;

        -- If no row found (card doesn't exist)
        IF v_user_id IS NULL AND v_balance IS NULL THEN
            SET p_success = FALSE;
            SET p_message = 'Gift card not found';
            LEAVE proc_end;
        END IF;

        -- Check ownership: user must match assigned user_id
        IF v_user_id IS NULL OR v_user_id != p_user_id THEN
            SET p_success = FALSE;
            SET p_message = 'User does not own this gift card or card is unassigned';
            LEAVE proc_end;
        END IF;

        -- Update status if expired
        IF v_expired AND v_status != 'expired' THEN
            UPDATE gift_cards SET status = 'expired', updated_at = NOW() WHERE card_id = p_card_id;
            SET p_success = FALSE;
            SET p_message = 'Gift card is expired';
            LEAVE proc_end;
        END IF;

        -- Check card status
        IF v_status != 'active' THEN
            SET p_success = FALSE;
            SET p_message = CONCAT('Gift card status is ', v_status);
            LEAVE proc_end;
        END IF;

        -- Balance check
        IF v_balance < p_amount THEN
            SET p_success = FALSE;
            SET p_message = 'Insufficient balance';
            LEAVE proc_end;
        END IF;

        -- Basic fraud detection
        IF p_amount > 1000 THEN
            SET p_success = FALSE;
            SET p_message = 'Transaction exceeds allowed limit';
            LEAVE proc_end;
        END IF;

        -- Update balance
        UPDATE gift_cards
        SET current_balance = current_balance - p_amount,
            updated_at = NOW()
        WHERE card_id = p_card_id;

        -- Log transaction
        INSERT INTO gift_card_transactions(card_id, user_id, transaction_type, amount, notes)
        VALUES (p_card_id, p_user_id, 'redemption', p_amount, 'Redemption');

        SET p_success = TRUE;
        SET p_message = 'Redemption successful';
    END proc_end;
END //

DELIMITER ;


                                                      #Recharge Gift Card
DELIMITER //

CREATE PROCEDURE recharge_gift_card (
    IN p_card_id CHAR(7),
    IN p_user_id INT,
    IN p_amount DECIMAL(10,2),
    OUT p_success BOOLEAN,
    OUT p_message VARCHAR(255)
)
BEGIN
    DECLARE v_status ENUM('active', 'inactive', 'blocked', 'expired');
 
 proc_end:Begin
    -- Check if card exists
    IF NOT EXISTS (SELECT 1 FROM gift_cards WHERE card_id = p_card_id) THEN
        SET p_success = FALSE;
        SET p_message = 'Gift card not found';
        LEAVE proc_end;
    END IF;

    SELECT status INTO v_status FROM gift_cards WHERE card_id = p_card_id;

    IF v_status != 'active' THEN
        SET p_success = FALSE;
        SET p_message = CONCAT('Gift card status is ', v_status);
        LEAVE proc_end;
    END IF;

    IF p_amount <= 0 THEN
        SET p_success = FALSE;
        SET p_message = 'Recharge amount must be positive';
        LEAVE proc_end;
    END IF;

    -- Update balance
    UPDATE gift_cards SET current_balance = current_balance + p_amount, updated_at = NOW()
    WHERE card_id = p_card_id;

    -- Log transaction
    INSERT INTO gift_card_transactions(card_id, user_id, transaction_type, amount, notes)
    VALUES (p_card_id, p_user_id, 'recharge', p_amount, 'Recharge');

    SET p_success = TRUE;
    SET p_message = 'Recharge successful';

    End proc_end;
END //

DELIMITER ;

                                               #Transfer Gift Card to another User
DELIMITER //

CREATE PROCEDURE transfer_gift_card (
    IN p_card_id CHAR(7),
    IN p_from_user INT,
    IN p_to_user INT,
    OUT p_success BOOLEAN,
    OUT p_message VARCHAR(255)
)
BEGIN
    DECLARE v_current_user INT;
    DECLARE v_status ENUM('active', 'inactive', 'blocked', 'expired');

 proc_end:Begin
    -- Check if card exists and belongs to from_user
    SELECT user_id, status INTO v_current_user, v_status FROM gift_cards WHERE card_id = p_card_id;

    IF v_current_user IS NULL THEN
        SET p_success = FALSE;
        SET p_message = 'Gift card is unassigned and cannot be transferred';
        LEAVE proc_end;
    END IF;

    IF v_current_user != p_from_user THEN
        SET p_success = FALSE;
        SET p_message = 'Gift card does not belong to the transferring user';
        LEAVE proc_end;
    END IF;

    IF v_status != 'active' THEN
        SET p_success = FALSE;
        SET p_message = CONCAT('Gift card status is ', v_status);
        LEAVE proc_end;
    END IF;

    -- Transfer card
    UPDATE gift_cards SET user_id = p_to_user, updated_at = NOW() WHERE card_id = p_card_id;

    -- Log transactions: transfer_out and transfer_in
    INSERT INTO gift_card_transactions(card_id, user_id, transaction_type, amount, notes)
    VALUES (p_card_id, p_from_user, 'transfer_out', 0, CONCAT('Transferred to user ', p_to_user));

    INSERT INTO gift_card_transactions(card_id, user_id, transaction_type, amount, notes)
    VALUES (p_card_id, p_to_user, 'transfer_in', 0, CONCAT('Received from user ', p_from_user));

    SET p_success = TRUE;
    SET p_message = 'Gift card transferred successfully';

    End proc_end;
END //

DELIMITER ;

                                                #Status Management(Block,inactive,expired)
DELIMITER //

CREATE PROCEDURE update_gift_card_status (
    IN p_card_id CHAR(7),
    IN p_new_status ENUM('active', 'inactive', 'blocked', 'expired'),
    OUT p_success BOOLEAN,
    OUT p_message VARCHAR(255)
)
BEGIN
 proc_end:Begin
    IF NOT EXISTS (SELECT 1 FROM gift_cards WHERE card_id = p_card_id) THEN
        SET p_success = FALSE;
        SET p_message = 'Gift card not found';
        LEAVE proc_end;
    END IF;

    UPDATE gift_cards SET status = p_new_status, updated_at = NOW() WHERE card_id = p_card_id;

    SET p_success = TRUE;
    SET p_message = CONCAT('Gift card status updated to ', p_new_status);

    End proc_end;
END //

DELIMITER ;

                                                       #Automatic Expiry Handling
DELIMITER //

CREATE PROCEDURE expire_gift_cards()
BEGIN
    UPDATE gift_cards
    SET status = 'expired', updated_at = NOW()
    WHERE expiration_date < CURDATE() AND status = 'active';
END //

DELIMITER ;

													   #Assign Card to specific user
DELIMITER //

CREATE PROCEDURE assign_gift_card_to_user (
    IN p_card_id CHAR(7),
    IN p_user_id INT
)
BEGIN
    UPDATE gift_cards
    SET user_id = p_user_id
    WHERE card_id = p_card_id;
END //

DELIMITER ;

-- Total issued cards
SELECT COUNT(*) AS total_issued FROM gift_cards;

-- Active cards
SELECT COUNT(*) AS active_cards FROM gift_cards WHERE status = 'active';

-- Expired cards
SELECT COUNT(*) AS expired_cards FROM gift_cards WHERE status = 'expired';

-- Inactive cards
select count(*) as inactive_cards from gift_cards where status = 'inactive';

-- Gift cards by user
SELECT user_id, COUNT(*) AS cards_count FROM gift_cards GROUP BY user_id;

INSERT INTO users (username, email) VALUES 
('John','John@example.com'),
('Joy','Joy@example.com'),
('Raju', 'Raju@example.com'),
('Mahesh', 'Mahesh@example.com'); 

select * from users;

-- Declare and call the procedure to single generate card
CALL generate_gift_card(100.00, CURDATE() + INTERVAL 30 DAY, 1, @card_id);

-- Bulk card generate but not assign to anyone
CALL bulk_generate_gift_cards(4, 100.00, DATE_ADD(CURDATE(), INTERVAL 30 DAY), NULL);

select * from gift_cards;

-- assign card to specific user_id
CALL assign_gift_card_to_user('3060185', 2);

-- Redeem Gift card
call redeem_gift_card('60cfca3',1,10,@success,@msg); -- This querry is run before transferring the gift card to user_id 3

-- To check total number of cards issued
SELECT COUNT(*) AS total_issued FROM gift_cards;

-- To update status of card
call update_gift_card_status('3060185','inactive',@success,@msg); 

-- To transfer gift card to another user
CALL transfer_gift_card('60cfca3', 1, 3, @success, @msg); -- This querry will transfer the card of user_id 1 to User_id 3

-- To Recharge card
CALL recharge_gift_card('3060185', 2, 100.00, @success, @message);
select @succes,@message; -- This will show the recharge success or not

-- To check total Redeem
SELECT IFNULL(SUM(amount),0) AS total_redeemed FROM gift_card_transactions WHERE transaction_type = 'redemption';

-- To check Current_balance 
select * from gift_cards where current_balance = 100;

-- To check gift_card_transactions
select * from gift_card_transactions;
select * from gift_cards;
select * from users;


