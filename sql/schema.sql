DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop;
USE shop;
CREATE TABLE users (
  user_id INT PRIMARY KEY, full_name VARCHAR(100) NOT NULL, email VARCHAR(150) NOT NULL,
  phone VARCHAR(40), birth_date DATE, national_id VARCHAR(20), created_at DATETIME NOT NULL
) ENGINE=InnoDB ENCRYPTED=NO;
CREATE TABLE addresses (
  address_id INT PRIMARY KEY, user_id INT NOT NULL, street VARCHAR(150), city VARCHAR(80),
  postal_code VARCHAR(20), country VARCHAR(60), FOREIGN KEY (user_id) REFERENCES users(user_id)
) ENGINE=InnoDB ENCRYPTED=NO;
CREATE TABLE payment_methods (
  payment_id INT PRIMARY KEY, user_id INT NOT NULL, card_holder VARCHAR(100), card_last4 CHAR(4),
  card_token CHAR(32), expiry CHAR(5), FOREIGN KEY (user_id) REFERENCES users(user_id)
) ENGINE=InnoDB ENCRYPTED=NO;
CREATE TABLE products (
  product_id INT PRIMARY KEY, name VARCHAR(100), category VARCHAR(40), price DECIMAL(8,2)
) ENGINE=InnoDB ENCRYPTED=NO;
CREATE TABLE orders (
  order_id INT PRIMARY KEY, user_id INT NOT NULL, order_date DATETIME, status VARCHAR(20),
  total DECIMAL(10,2), FOREIGN KEY (user_id) REFERENCES users(user_id)
) ENGINE=InnoDB ENCRYPTED=NO;
CREATE TABLE order_items (
  order_id INT, product_id INT, quantity INT, unit_price DECIMAL(8,2),
  PRIMARY KEY (order_id, product_id),
  FOREIGN KEY (order_id) REFERENCES orders(order_id),
  FOREIGN KEY (product_id) REFERENCES products(product_id)
) ENGINE=InnoDB ENCRYPTED=NO;
