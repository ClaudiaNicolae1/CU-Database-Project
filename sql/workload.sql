SELECT * FROM users WHERE user_id=123456;
SELECT o.order_id,o.total,u.full_name FROM orders o JOIN users u ON u.user_id=o.user_id WHERE o.order_id BETWEEN 500000 AND 500100;
UPDATE users SET phone='+49 1' WHERE user_id=654321;
SELECT status,COUNT(*),SUM(total) FROM orders GROUP BY status;
SELECT p.category,SUM(i.quantity*i.unit_price) FROM order_items i JOIN products p ON p.product_id=i.product_id GROUP BY p.category;
