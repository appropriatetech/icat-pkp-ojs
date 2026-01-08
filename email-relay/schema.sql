CREATE TABLE IF NOT EXISTS email_queue (
    id INT AUTO_INCREMENT PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status ENUM('pending', 'sent', 'failed') DEFAULT 'pending',
    attempt_count INT DEFAULT 0,
    last_attempt_at TIMESTAMP NULL,
    error_message TEXT,
    sender VARCHAR(255) NOT NULL,
    recipients TEXT NOT NULL,
    body MEDIUMBLOB NOT NULL,
    INDEX idx_status_created (status, created_at)
);
