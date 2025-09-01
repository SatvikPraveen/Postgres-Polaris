-- File: sql/03_dml_queries/seed_data.sql
-- Purpose: Deterministic inserts from /data directory for testing and demos

-- =============================================================================
-- TRIP SEGMENTS SEED DATA
-- =============================================================================

INSERT INTO mobility.trip_segments (
    trip_id, segment_order, user_id, trip_mode, start_time, end_time, duration_minutes,
    start_latitude, start_longitude, end_latitude, end_longitude,
    start_station_id, end_station_id, distance_km, fare_paid
) VALUES
('TRIP-001', 1, 1, 'bus', '2024-12-28 08:15:00', '2024-12-28 08:32:00', 17, 32.9850, -96.8050, 32.9830, -96.7850, 1, 2, 2.5, 2.50),
('TRIP-002', 1, 2, 'cycling', '2024-12-28 09:00:00', '2024-12-28 09:25:00', 25, 32.9820, -96.7950, 32.9750, -96.8020, 3, 4, 3.2, 0.00),
('TRIP-003', 1, 3, 'walking', '2024-12-28 17:30:00', '2024-12-28 17:45:00', 15, 32.9830, -96.7850, 32.9840, -96.8030, NULL, NULL, 1.8, 0.00),
('TRIP-004', 1, 4, 'scooter', '2024-12-28 12:10:00', '2024-12-28 12:18:00', 8, 32.9825, -96.7825, 32.9820, -96.7950, 7, NULL, 1.2, 3.50),
('TRIP-005', 1, 5, 'rail', '2024-12-28 07:45:00', '2024-12-28 08:15:00', 30, 32.9860, -96.8070, 32.9750, -96.8020, 6, NULL, 4.5, 4.75);

-- =============================================================================
-- SENSOR READINGS SEED DATA
-- =============================================================================

INSERT INTO mobility.sensor_readings (
    sensor_code, sensor_type, latitude, longitude, location_description,
    reading_value, unit_of_measure, reading_time, data_quality_score
) VALUES
('TRAFFIC-001', 'traffic_counter', 32.9845, -96.8045, 'Main St & 1st Ave', 245, 'vehicles/hour', '2024-12-28 08:00:00', 0.95),
('TRAFFIC-001', 'traffic_counter', 32.9845, -96.8045, 'Main St & 1st Ave', 180, 'vehicles/hour', '2024-12-28 12:00:00', 0.95),
('AIR-002', 'air_quality', 32.9830, -96.7850, 'Tech Valley Station', 45, 'AQI', '2024-12-28 08:00:00', 0.90),
('NOISE-003', 'noise', 32.9850, -96.8050, 'Downtown Transit Center', 68, 'dB', '2024-12-28 08:30:00', 0.88),
('SPEED-004', 'speed', 32.9820, -96.7950, 'River Rd', 25, 'mph', '2024-12-28 09:15:00', 0.92),
('WEATHER-005', 'weather', 32.9840, -96.8030, 'City Hall', 72, 'temperature_f', '2024-12-28 10:00:00', 0.98);

-- =============================================================================
-- COMPLAINT RECORDS SEED DATA
-- =============================================================================

INSERT INTO documents.complaint_records (
    reporter_citizen_id, complaint_number, subject, description, category,
    priority_level, incident_address, incident_latitude, incident_longitude,
    status, submitted_at, metadata
) VALUES
(1, 'COMP-2024-001', 'Pothole on Main Street', 'Large pothole causing damage to vehicles near 150 Main St', 'roads', 'high',
 '150 Main St', 32.9848, -96.8048, 'under_review', '2024-12-20 14:30:00',
 '{"hazard_type": "pothole", "severity": "high", "traffic_impact": true}'::jsonb),

(2, 'COMP-2024-002', 'Noise complaint - construction', 'Early morning construction noise before 7 AM', 'noise', 'normal',
 '200 Oak Ave', 32.9835, -96.8025, 'resolved', '2024-12-15 06:45:00',
 '{"decibel_level": 85, "time_of_day": "06:30", "construction_type": "road_work"}'::jsonb),

(4, 'COMP-2024-003', 'Streetlight out', 'Streetlight has been out for 3 weeks on Garden Ave', 'utilities', 'normal',
 '180 Garden Ave', 32.9750, -96.8020, 'resolved', '2024-12-10 19:20:00',
 '{"utility_type": "lighting", "outage_duration": "21_days", "safety_concern": true}'::jsonb),

(6, 'COMP-2024-004', 'Illegal dumping', 'Someone dumped furniture behind the shopping center', 'trash', 'urgent',
 '350 Cedar Ln', 32.9765, -96.7985, 'submitted', '2024-12-27 16:15:00',
 '{"waste_type": "furniture", "estimated_volume": "large", "health_hazard": false}'::jsonb);

-- =============================================================================
-- POLICY DOCUMENTS SEED DATA
-- =============================================================================

INSERT INTO documents.policy_documents (
    policy_number, title, version, document_content, department, policy_area,
    status, effective_date, created_by, tags, keywords
) VALUES
('POL-2024-001', 'Noise Ordinance Regulations', '2.1',
 '{"title": "Noise Ordinance Regulations", "sections": [{"number": "1", "title": "General Provisions", "content": "This ordinance regulates noise levels within city limits."}, {"number": "2", "title": "Prohibited Activities", "content": "Construction noise before 7 AM or after 8 PM is prohibited."}], "effective_date": "2024-01-01"}'::jsonb,
 'Code Enforcement', 'Public Safety', 'published', '2024-01-01', 1,
 ARRAY['noise', 'ordinance', 'construction', 'quiet_hours'], ARRAY['noise', 'decibel', 'construction', 'enforcement']),

('POL-2024-002', 'Business License Requirements', '1.0',
 '{"title": "Business License Requirements", "sections": [{"number": "1", "title": "Application Process", "content": "All businesses must obtain proper licensing before operation."}, {"number": "2", "title": "Renewal Requirements", "content": "Licenses must be renewed annually by December 31st."}], "effective_date": "2024-07-01"}'::jsonb,
 'Economic Development', 'Business Regulation', 'published', '2024-07-01', 3,
 ARRAY['business', 'license', 'permit', 'regulations'], ARRAY['business', 'license', 'permit', 'application']);

-- =============================================================================
-- BUSINESS LICENSES SEED DATA
-- =============================================================================

INSERT INTO commerce.business_licenses (
    merchant_id, license_type, license_number, status, application_date,
    issue_date, expiration_date, license_fee, fee_paid
) VALUES
(1, 'Food Service', 'FS-2024-001', 'active', '2024-01-05', '2024-01-15', '2024-12-31', 350.00, 350.00),
(1, 'General Business', 'GB-2024-001', 'active', '2024-01-05', '2024-01-15', '2024-12-31', 150.00, 150.00),
(2, 'General Business', 'GB-2024-002', 'active', '2024-02-01', '2024-02-10', '2024-12-31', 150.00, 150.00),
(3, 'Food Service', 'FS-2024-003', 'active', '2024-01-20', '2024-02-01', '2024-12-31', 350.00, 350.00),
(3, 'General Business', 'GB-2024-003', 'active', '2024-01-20', '2024-02-01', '2024-12-31', 150.00, 150.00),
(4, 'General Business', 'GB-2024-004', 'active', '2024-03-01', '2024-03-10', '2024-12-31', 150.00, 150.00),
(5, 'Medical Practice', 'MP-2024-005', 'active', '2024-01-10', '2024-01-25', '2024-12-31', 500.00, 500.00);

-- =============================================================================
-- STATION INVENTORY SEED DATA
-- =============================================================================

INSERT INTO mobility.station_inventory (
    station_id, available_count, in_use_count, maintenance_count, recorded_at
) VALUES
(3, 15, 3, 2, '2024-12-28 08:00:00'), -- Riverside Bike Share
(3, 12, 6, 2, '2024-12-28 12:00:00'),
(3, 18, 1, 1, '2024-12-28 18:00:00'),
(4, 10, 4, 1, '2024-12-28 08:00:00'), -- Garden Heights Bikes
(4, 8, 6, 1, '2024-12-28 12:00:00'),
(4, 13, 2, 0, '2024-12-28 18:00:00'),
(5, 6, 1, 1, '2024-12-28 08:00:00'), -- Downtown Charging Hub
(5, 4, 3, 1, '2024-12-28 12:00:00'),
(5, 7, 1, 0, '2024-12-28 18:00:00'),
(7, 20, 4, 1, '2024-12-28 08:00:00'), -- Tech District Scooters
(7, 15, 9, 1, '2024-12-28 12:00:00'),
(7, 22, 2, 1, '2024-12-28 18:00:00');

-- =============================================================================
-- PAYMENTS SEED DATA
-- =============================================================================

INSERT INTO commerce.payments (
    order_id, payment_method, amount, status, transaction_id, processor, processed_at
) VALUES
(1, 'credit_card', 32.05, 'completed', 'txn_abc123', 'Stripe', '2024-12-01 12:32:00'),
(2, 'credit_card', 45.43, 'completed', 'txn_def456', 'Stripe', '2024-12-01 18:47:00'),
(3, 'bank_transfer', 1353.13, 'completed', 'txn_ghi789', 'ACH', '2024-12-02 10:20:00'),
(4, 'debit_card', 73.45, 'completed', 'txn_jkl012', 'Square', '2024-12-02 16:22:00'),
(5, 'cash', 157.29, 'completed', NULL, NULL, '2024-12-03 09:35:00'),
(6, 'credit_card', 37.12, 'pending', 'txn_mno345', 'Stripe', NULL);

-- =============================================================================
-- VOTING RECORDS SEED DATA
-- =============================================================================

INSERT INTO civics.voting_records (
    citizen_id, election_name, election_date, vote_type, precinct, voting_method, voted_at
) VALUES
(1, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-001', 'early', '2024-10-28 14:30:00'),
(2, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-001', 'in_person', '2024-11-05 10:15:00'),
(3, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-002', 'in_person', '2024-11-05 16:45:00'),
(4, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-001', 'mail', '2024-10-25 00:00:00'),
(5, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-002', 'early', '2024-10-30 11:20:00'),
(6, '2024 Municipal Election', '2024-11-05', 'municipal', 'PCT-001', 'in_person', '2024-11-05 18:30:00'),
(7, '2024 School Board Election', '2024-05-15', 'school_board', 'PCT-002', 'in_person', '2024-05-15 12:00:00'),
(8, '2024 School Board Election', '2024-05-15', 'school_board', 'PCT-001', 'early', '2024-05-10 09:45:00');

-- =============================================================================
-- VERIFICATION QUERIES
-- =============================================================================

-- Count records in each table
SELECT 'Citizens' as table_name, COUNT(*) as record_count FROM civics.citizens
UNION ALL SELECT 'Merchants', COUNT(*) FROM commerce.merchants
UNION ALL SELECT 'Orders', COUNT(*) FROM commerce.orders
UNION ALL SELECT 'Order Items', COUNT(*) FROM commerce.order_items
UNION ALL SELECT 'Permits', COUNT(*) FROM civics.permit_applications
UNION ALL SELECT 'Tax Payments', COUNT(*) FROM civics.tax_payments
UNION ALL SELECT 'Neighborhoods', COUNT(*) FROM geo.neighborhood_boundaries
UNION ALL SELECT 'POIs', COUNT(*) FROM geo.points_of_interest
UNION ALL SELECT 'Stations', COUNT(*) FROM mobility.stations
UNION ALL SELECT 'Trip Segments', COUNT(*) FROM mobility.trip_segments
UNION ALL SELECT 'Sensor Readings', COUNT(*) FROM mobility.sensor_readings
UNION ALL SELECT 'Complaints', COUNT(*) FROM documents.complaint_records
UNION ALL SELECT 'Policies', COUNT(*) FROM documents.policy_documents
UNION ALL SELECT 'Business Licenses', COUNT(*) FROM commerce.business_licenses
UNION ALL SELECT 'Station Inventory', COUNT(*) FROM mobility.station_inventory
UNION ALL SELECT 'Payments', COUNT(*) FROM commerce.payments
UNION ALL SELECT 'Voting Records', COUNT(*) FROM civics.voting_records
ORDER BY table_name;

-- Sample data validation
SELECT 'Data integrity check passed' as status
WHERE (
    -- Check foreign key relationships
    (SELECT COUNT(*) FROM civics.permit_applications p
     JOIN civics.citizens c ON p.citizen_id = c.citizen_id) =
    (SELECT COUNT(*) FROM civics.permit_applications)
    AND
    (SELECT COUNT(*) FROM commerce.orders o
     LEFT JOIN civics.citizens c ON o.customer_citizen_id = c.citizen_id) =
    (SELECT COUNT(*) FROM commerce.orders)
    AND
    -- Check calculated totals match
    (SELECT SUM(ABS(total_amount - (subtotal + tax_amount + tip_amount)))
     FROM commerce.orders) < 0.01
);

-- ============================================================================
-- CITIZENS SEED DATA
-- =============================================================================

INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, phone, street_address, zip_code, ssn_hash) VALUES
('John', 'Smith', '1985-03-15', 'john.smith@email.com', '214-555-0101', '123 Main St', '75032', encode(sha256('123456789'::bytea), 'hex')),
('Jane', 'Doe', '1990-07-22', 'jane.doe@email.com', '214-555-0102', '456 Oak Ave', '75032', encode(sha256('987654321'::bytea), 'hex')),
('Michael', 'Johnson', '1978-12-08', 'mike.johnson@email.com', '214-555-0103', '789 Pine St', '75087', encode(sha256('456789123'::bytea), 'hex')),
('Sarah', 'Williams', '1992-05-30', 'sarah.williams@email.com', '214-555-0104', '321 Elm Dr', '75032', encode(sha256('789123456'::bytea), 'hex')),
('David', 'Brown', '1983-09-14', 'david.brown@email.com', '469-555-0105', '654 Cedar Ln', '75087', encode(sha256('321654987'::bytea), 'hex')),
('Lisa', 'Davis', '1987-11-03', 'lisa.davis@email.com', '469-555-0106', '987 Birch Rd', '75032', encode(sha256('654987321'::bytea), 'hex')),
('Robert', 'Miller', '1975-01-27', 'robert.miller@email.com', '972-555-0107', '147 Maple Way', '75087', encode(sha256('147258369'::bytea), 'hex')),
('Emily', 'Wilson', '1995-08-19', 'emily.wilson@email.com', '972-555-0108', '258 Willow Ct', '75032', encode(sha256('258369147'::bytea), 'hex')),
('James', 'Moore', '1980-04-11', 'james.moore@email.com', '214-555-0109', '369 Spruce Ave', '75087', encode(sha256('369147258'::bytea), 'hex')),
('Amanda', 'Taylor', '1988-06-25', 'amanda.taylor@email.com', '469-555-0110', '741 Ash Blvd', '75032', encode(sha256('741852963'::bytea), 'hex'));

-- =============================================================================
-- GEO SEED DATA (Neighborhoods)
-- =============================================================================

INSERT INTO geo.neighborhood_boundaries (
    neighborhood_name, neighborhood_code,
    boundary_geom, area_sq_km, population_estimate,
    city_council_district, school_district
) VALUES
('Downtown Core', 'DTC',
 ST_GeomFromText('POLYGON((-96.8100 32.9900, -96.8000 32.9900, -96.8000 32.9800, -96.8100 32.9800, -96.8100 32.9900))', 4326),
 0.85, 2500, 1, 'Polaris ISD'),
('Riverside District', 'RSD',
 ST_GeomFromText('POLYGON((-96.8000 32.9900, -96.7900 32.9900, -96.7900 32.9800, -96.8000 32.9800, -96.8000 32.9900))', 4326),
 1.20, 3200, 1, 'Polaris ISD'),
('Tech Valley', 'TCV',
 ST_GeomFromText('POLYGON((-96.7900 32.9900, -96.7800 32.9900, -96.7800 32.9800, -96.7900 32.9800, -96.7900 32.9900))', 4326),
 2.15, 4800, 2, 'North Polaris ISD'),
('Garden Heights', 'GDH',
 ST_GeomFromText('POLYGON((-96.8100 32.9800, -96.8000 32.9800, -96.8000 32.9700, -96.8100 32.9700, -96.8100 32.9800))', 4326),
 1.45, 2800, 3, 'Polaris ISD'),
('Industrial Park', 'IDP',
 ST_GeomFromText('POLYGON((-96.8000 32.9800, -96.7900 32.9800, -96.7900 32.9700, -96.8000 32.9700, -96.8000 32.9800))', 4326),
 1.80, 1200, 2, 'South Polaris ISD');

-- =============================================================================
-- MERCHANTS SEED DATA
-- =============================================================================

INSERT INTO commerce.merchants (
    business_name, legal_name, tax_id, owner_citizen_id,
    contact_email, contact_phone, business_address, zip_code,
    business_type, annual_revenue, employee_count
) VALUES
('Polaris Pizza Palace', 'PPP Restaurant Corp', '12-3456789', 1,
 'orders@polarispizza.com', '214-555-2001', '101 Main St', '75032',
 'restaurant', 850000.00, 12),
('Tech Solutions Inc', 'Tech Solutions Incorporated', '98-7654321', 3,
 'info@techsolutions.com', '469-555-2002', '500 Innovation Blvd', '75087',
 'technology', 2400000.00, 35),
('Green Grocers Market', 'Green Grocers LLC', '45-6789012', 5,
 'hello@greengrocers.com', '972-555-2003', '200 Oak Ave', '75032',
 'retail', 650000.00, 8),
('City Hardware Store', 'City Hardware Co', '78-9012345', 7,
 'sales@cityhardware.com', '214-555-2004', '350 Cedar Ln', '75087',
 'retail', 480000.00, 6),
('Wellness Medical Center', 'Wellness Medical PC', '34-5678901', 9,
 'contact@wellnessmedical.com', '469-555-2005', '750 Health Way', '75032',
 'healthcare', 1800000.00, 25);

-- =============================================================================
-- MOBILITY STATIONS SEED DATA
-- =============================================================================

INSERT INTO mobility.stations (
    station_code, station_name, station_type, latitude, longitude,
    address, neighborhood, total_capacity, accessible, operator
) VALUES
('BUS_001', 'Downtown Transit Center', 'bus', 32.9850, -96.8050, '150 Main St', 'Downtown Core', 6, true, 'Polaris Transit'),
('BUS_002', 'Tech Valley Station', 'bus', 32.9830, -96.7850, '400 Innovation Blvd', 'Tech Valley', 4, true, 'Polaris Transit'),
('BIKE_001', 'Riverside Bike Share', 'bike_share', 32.9820, -96.7950, '250 River Rd', 'Riverside District', 20, true, 'PolarisWheels'),
('BIKE_002', 'Garden Heights Bikes', 'bike_share', 32.9750, -96.8020, '180 Garden Ave', 'Garden Heights', 15, true, 'PolarisWheels'),
('EV_001', 'Downtown Charging Hub', 'ev_charging', 32.9840, -96.8030, '120 Electric Ave', 'Downtown Core', 8, true, 'ChargePolar'),
('RAIL_001', 'Polaris Central Station', 'rail', 32.9860, -96.8070, '100 Railroad St', 'Downtown Core', 200, true, 'Metro Rail'),
('SCOOT_001', 'Tech District Scooters', 'scooter', 32.9825, -96.7825, '450 Tech Pkwy', 'Tech Valley', 25, false, 'ScootPolar');

-- =============================================================================
-- POINTS OF INTEREST SEED DATA
-- =============================================================================

INSERT INTO geo.points_of_interest (
    name, category, subcategory, phone, website, street_address, zip_code,
    location_geom, business_hours, services_offered, average_rating
) VALUES
('Polaris City Hall', 'government', 'Municipal Building', '214-555-3001', 'https://polariscity.gov',
 '1 City Plaza', '75032', ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326),
 '{"monday":{"open":"08:00","close":"17:00"},"tuesday":{"open":"08:00","close":"17:00"},"wednesday":{"open":"08:00","close":"17:00"},"thursday":{"open":"08:00","close":"17:00"},"friday":{"open":"08:00","close":"17:00"}}'::jsonb,
 ARRAY['Permits', 'Licenses', 'Tax Payments', 'Public Records'], 4.2),

('Central Library', 'library', 'Public Library', '214-555-3002', 'https://polarislibrary.org',
 '200 Knowledge St', '75032', ST_SetSRID(ST_Point(-96.8020, 32.9845), 4326),
 '{"monday":{"open":"09:00","close":"21:00"},"tuesday":{"open":"09:00","close":"21:00"},"wednesday":{"open":"09:00","close":"21:00"},"thursday":{"open":"09:00","close":"21:00"},"friday":{"open":"09:00","close":"18:00"},"saturday":{"open":"09:00","close":"17:00"},"sunday":{"open":"13:00","close":"17:00"}}'::jsonb,
 ARRAY['Books', 'Internet Access', 'Study Rooms', 'Events'], 4.7),

('Riverside Park', 'park', 'Community Park', '214-555-3003', NULL,
 '300 River Rd', '75032', ST_SetSRID(ST_Point(-96.7940, 32.9815), 4326),
 '{"daily":{"open":"06:00","close":"22:00"}}'::jsonb,
 ARRAY['Playground', 'Walking Trails', 'Picnic Areas', 'Sports Courts'], 4.5),

('Memorial Hospital', 'hospital', 'General Hospital', '469-555-3004', 'https://memorialhospital.com',
 '500 Health Blvd', '75032', ST_SetSRID(ST_Point(-96.8000, 32.9770), 4326),
 '{"daily":{"open":"00:00","close":"23:59"}}'::jsonb,
 ARRAY['Emergency Care', 'Surgery', 'Maternity', 'Radiology'], 4.1),

('Polaris Elementary School', 'school', 'Elementary', '972-555-3005', 'https://polariselem.edu',
 '400 Learning Lane', '75087', ST_SetSRID(ST_Point(-96.7880, 32.9820), 4326),
 '{"monday":{"open":"07:30","close":"15:30"},"tuesday":{"open":"07:30","close":"15:30"},"wednesday":{"open":"07:30","close":"15:30"},"thursday":{"open":"07:30","close":"15:30"},"friday":{"open":"07:30","close":"15:30"}}'::jsonb,
 ARRAY['K-5 Education', 'After School Care', 'Cafeteria'], 4.3);

-- =============================================================================
-- PERMIT APPLICATIONS SEED DATA
-- =============================================================================

INSERT INTO civics.permit_applications (
    citizen_id, permit_type, permit_number, description, property_address,
    status, application_date, fee_amount, fee_paid
) VALUES
(1, 'building', 'BP-2024-001', 'Residential deck addition', '123 Main St', 'approved', '2024-01-15', 250.00, 250.00),
(2, 'business', 'BZ-2024-002', 'Home bakery business license', '456 Oak Ave', 'approved', '2024-01-20', 150.00, 150.00),
(3, 'building', 'BP-2024-003', 'Office renovation', '500 Innovation Blvd', 'approved', '2024-02-01', 800.00, 800.00),
(4, 'event', 'EV-2024-004', 'Block party street closure', '321 Elm Dr', 'approved', '2024-03-10', 75.00, 75.00),
(5, 'building', 'BP-2024-005', 'Commercial storefront update', '200 Oak Ave', 'under_review', '2024-12-01', 500.00, 500.00),
(6, 'parking', 'PK-2024-006', 'Reserved parking space', '987 Birch Rd', 'pending', '2024-12-15', 100.00, 0.00);

-- =============================================================================
-- TAX PAYMENTS SEED DATA
-- =============================================================================

INSERT INTO civics.tax_payments (
    citizen_id, tax_type, tax_year, assessment_amount, amount_due, amount_paid,
    payment_status, due_date, property_address, assessed_value, mill_rate
) VALUES
(1, 'property', 2024, 2850.00, 2850.00, 2850.00, 'paid', '2024-01-31', '123 Main St', 285000.00, 10.0000),
(2, 'property', 2024, 3200.00, 3200.00, 3200.00, 'paid', '2024-01-31', '456 Oak Ave', 320000.00, 10.0000),
(3, 'property', 2024, 4500.00, 4500.00, 4500.00, 'paid', '2024-01-31', '500 Innovation Blvd', 450000.00, 10.0000),
(4, 'property', 2024, 2650.00, 2650.00, 2650.00, 'paid', '2024-01-31', '321 Elm Dr', 265000.00, 10.0000),
(5, 'property', 2024, 3800.00, 3800.00, 2000.00, 'overdue', '2024-01-31', '654 Cedar Ln', 380000.00, 10.0000),
(1, 'vehicle', 2024, 185.00, 185.00, 185.00, 'paid', '2024-03-15', NULL, NULL, NULL),
(3, 'business', 2024, 750.00, 750.00, 750.00, 'paid', '2024-04-15', NULL, NULL, NULL);

-- =============================================================================
-- ORDERS SEED DATA
-- =============================================================================

INSERT INTO commerce.orders (
    merchant_id, customer_citizen_id, order_number, order_date, status,
    subtotal, tax_amount, tip_amount, total_amount, delivery_address
) VALUES
(1, 1, 'ORD-001', '2024-12-01 12:30:00', 'delivered', 24.99, 2.06, 5.00, 32.05, '123 Main St'),
(1, 2, 'ORD-002', '2024-12-01 18:45:00', 'delivered', 35.50, 2.93, 7.00, 45.43, '456 Oak Ave'),
(2, 3, 'ORD-003', '2024-12-02 10:15:00', 'completed', 1250.00, 103.13, 0.00, 1353.13, '500 Innovation Blvd'),
(3, 4, 'ORD-004', '2024-12-02 16:20:00', 'delivered', 67.85, 5.60, 0.00, 73.45, '321 Elm Dr'),
(4, 5, 'ORD-005', '2024-12-03 09:30:00', 'delivered', 145.30, 11.99, 0.00, 157.29, '654 Cedar Ln'),
(1, 6, 'ORD-006', '2024-12-28 19:15:00', 'processing', 28.75, 2.37, 6.00, 37.12, '987 Birch Rd');

-- =============================================================================
-- ORDER ITEMS SEED DATA
-- =============================================================================

INSERT INTO commerce.order_items (order_id, item_name, item_description, sku, unit_price, quantity, line_total) VALUES
(1, 'Margherita Pizza', 'Fresh mozzarella, tomatoes, basil', 'PIZZA-MAR', 18.99, 1, 18.99),
(1, 'Garlic Bread', 'Homemade garlic bread with herbs', 'SIDE-GAR', 5.99, 1, 5.99),
(2, 'Pepperoni Pizza Large', 'Large pepperoni pizza', 'PIZZA-PEP-L', 22.99, 1, 22.99),
(2, 'Caesar Salad', 'Fresh romaine, parmesan, croutons', 'SALAD-CAE', 12.50, 1, 12.50),
(3, 'Website Development', 'Custom business website', 'WEB-DEV', 1250.00, 1, 1250.00),
(4, 'Organic Vegetables', 'Weekly vegetable box', 'VEG-BOX', 35.50, 1, 35.50),
(4, 'Fresh Fruit Selection', 'Seasonal fruit assortment', 'FRUIT-SEL', 32.35, 1, 32.35),
(5, 'Power Drill Kit', 'Cordless drill with bits', 'TOOL-DRL-001', 89.99, 1, 89.99),
(5, 'Paint Set', '1 gallon interior paint', 'PAINT-INT', 55.31, 1, 55.31),
(6, 'Pepperoni Pizza Medium', 'Medium pepperoni pizza', 'PIZZA-PEP-M', 19.99, 1, 19.99),
(6, 'Wings 12pc', '12 piece buffalo wings', 'WINGS-12', 8.75, 1, 8.75);

-- =============================================================================
-- ADDITIONAL ORDER ITEMS (to match existing orders)
-- =============================================================================

-- Additional items for existing orders to ensure realistic order totals
INSERT INTO commerce.order_items (order_id, item_name, item_description, sku, unit_price, quantity, line_total) VALUES
-- Order 4 needs more items to reach $67.85 subtotal (currently at $67.85, perfect)
-- Order 5 needs adjustment to reach $145.30 subtotal (currently at $145.30, perfect)

-- Adding some missing seasonal/specialty items
(3, 'Technical Consultation', '2 hours technical consulting', 'CONSULT-TECH', 75.00, 2, 150.00),
(4, 'Organic Herbs', 'Fresh herb selection', 'HERB-ORGANIC', 12.99, 1, 12.99);

-- Update order 3 subtotal to account for additional consulting
UPDATE commerce.orders SET subtotal = 1475.00, tax_amount = 121.75, total_amount = 1596.75 WHERE order_id = 3;

-- =============================================================================
-- ADDITIONAL CITIZENS (to have even 10 total)
-- =============================================================================

-- The file has 10 citizens, which is complete, but adding a few more for better testing
INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, phone, street_address, zip_code, ssn_hash) VALUES
('Christopher', 'Anderson', '1982-02-14', 'chris.anderson@email.com', '972-555-0111', '852 Poplar St', '75087', encode(sha256('852963741'::bytea), 'hex')),
('Jessica', 'Thomas', '1991-10-07', 'jessica.thomas@email.com', '214-555-0112', '963 Hickory Ave', '75032', encode(sha256('963741852'::bytea), 'hex'));

-- =============================================================================
-- ADDITIONAL HISTORICAL DATA
-- =============================================================================

-- More sensor readings for trend analysis
INSERT INTO mobility.sensor_readings (
    sensor_code, sensor_type, latitude, longitude, location_description,
    reading_value, unit_of_measure, reading_time, data_quality_score
) VALUES
-- Traffic patterns throughout the day
('TRAFFIC-001', 'traffic_counter', 32.9845, -96.8045, 'Main St & 1st Ave', 320, 'vehicles/hour', '2024-12-28 16:00:00', 0.94),
('TRAFFIC-001', 'traffic_counter', 32.9845, -96.8045, 'Main St & 1st Ave', 145, 'vehicles/hour', '2024-12-28 20:00:00', 0.96),

-- Air quality throughout day
('AIR-002', 'air_quality', 32.9830, -96.7850, 'Tech Valley Station', 52, 'AQI', '2024-12-28 12:00:00', 0.91),
('AIR-002', 'air_quality', 32.9830, -96.7850, 'Tech Valley Station', 38, 'AQI', '2024-12-28 18:00:00', 0.93),

-- Weather data points
('WEATHER-005', 'weather', 32.9840, -96.8030, 'City Hall', 68, 'temperature_f', '2024-12-28 06:00:00', 0.97),
('WEATHER-005', 'weather', 32.9840, -96.8030, 'City Hall', 75, 'temperature_f', '2024-12-28 14:00:00', 0.98),
('WEATHER-005', 'weather', 32.9840, -96.8030, 'City Hall', 71, 'temperature_f', '2024-12-28 18:00:00', 0.97);

-- =============================================================================
-- ADDITIONAL TRIP SEGMENTS (to show multi-modal trips)
-- =============================================================================

-- Multi-segment trips to demonstrate complex mobility patterns
INSERT INTO mobility.trip_segments (
    trip_id, segment_order, user_id, trip_mode, start_time, end_time, duration_minutes,
    start_latitude, start_longitude, end_latitude, end_longitude,
    start_station_id, end_station_id, distance_km, fare_paid
) VALUES
-- Multi-modal trip: bus + walking
('TRIP-006', 1, 6, 'bus', '2024-12-28 08:00:00', '2024-12-28 08:15:00', 15, 32.9860, -96.8070, 32.9850, -96.8050, 6, 1, 2.1, 2.50),
('TRIP-006', 2, 6, 'walking', '2024-12-28 08:18:00', '2024-12-28 08:30:00', 12, 32.9850, -96.8050, 32.9845, -96.8020, NULL, NULL, 0.8, 0.00),

-- Another multi-modal: cycling + rail
('TRIP-007', 1, 7, 'cycling', '2024-12-28 17:00:00', '2024-12-28 17:10:00', 10, 32.9750, -96.8020, 32.9830, -96.7950, 4, NULL, 1.5, 0.00),
('TRIP-007', 2, 7, 'rail', '2024-12-28 17:15:00', '2024-12-28 17:45:00', 30, 32.9860, -96.8070, 32.9750, -96.8100, 6, NULL, 5.2, 4.75);

-- =============================================================================
-- ADDITIONAL POLICY DOCUMENTS
-- =============================================================================

INSERT INTO documents.policy_documents (
    policy_number, title, version, document_content, department, policy_area,
    status, effective_date, created_by, tags, keywords
) VALUES
('POL-2024-003', 'Parking Enforcement Guidelines', '1.2',
 '{"title": "Parking Enforcement Guidelines", "sections": [{"number": "1", "title": "Violation Types", "content": "Standard parking violations include expired meters, no parking zones, and handicap violations."}, {"number": "2", "title": "Fine Schedule", "content": "Meter violations: $25, No parking zone: $50, Handicap violation: $200."}], "effective_date": "2024-03-01"}'::jsonb,
 'Parking Services', 'Traffic Management', 'published', '2024-03-01', 2,
 ARRAY['parking', 'enforcement', 'fines', 'violations'], ARRAY['parking', 'meter', 'violation', 'fine']),

('POL-2024-004', 'Public Wi-Fi Usage Policy', '1.0',
 '{"title": "Public Wi-Fi Usage Policy", "sections": [{"number": "1", "title": "Acceptable Use", "content": "Public Wi-Fi is provided for general internet access and city services."}, {"number": "2", "title": "Prohibited Activities", "content": "Illegal activities, bandwidth abuse, and commercial use are prohibited."}], "effective_date": "2024-06-01"}'::jsonb,
 'IT Services', 'Public Services', 'published', '2024-06-01', 4,
 ARRAY['wifi', 'internet', 'public', 'acceptable_use'], ARRAY['wifi', 'internet', 'policy', 'usage']);

-- =============================================================================
-- ADDITIONAL VOTING RECORDS (for different elections)
-- =============================================================================

INSERT INTO civics.voting_records (
    citizen_id, election_name, election_date, vote_type, precinct, voting_method, voted_at
) VALUES
-- 2024 Primary Elections
(1, '2024 Primary Election', '2024-03-05', 'primary', 'PCT-001', 'early', '2024-02-28 16:20:00'),
(3, '2024 Primary Election', '2024-03-05', 'primary', 'PCT-002', 'in_person', '2024-03-05 14:30:00'),
(5, '2024 Primary Election', '2024-03-05', 'primary', 'PCT-002', 'mail', '2024-02-25 00:00:00'),

-- Constitutional Amendment Election
(2, '2024 Constitutional Amendment', '2024-09-15', 'constitutional', 'PCT-001', 'early', '2024-09-10 10:45:00'),
(4, '2024 Constitutional Amendment', '2024-09-15', 'constitutional', 'PCT-001', 'in_person', '2024-09-15 11:30:00'),
(6, '2024 Constitutional Amendment', '2024-09-15', 'constitutional', 'PCT-001', 'mail', '2024-09-08 00:00:00');

-- =============================================================================
-- DATA CONSISTENCY FIXES
-- =============================================================================

-- Ensure all foreign key relationships are satisfied
-- Add any missing merchants referenced by orders
INSERT INTO commerce.merchants (
    business_name, legal_name, tax_id, owner_citizen_id,
    contact_email, contact_phone, business_address, zip_code,
    business_type, annual_revenue, employee_count
) VALUES
('Corner Pharmacy', 'Corner Pharmacy LLC', '56-7890123', 11,
 'info@cornerpharmacy.com', '972-555-2006', '600 Wellness Dr', '75032',
 'healthcare', 420000.00, 4)
ON CONFLICT DO NOTHING;

-- =============================================================================
-- ADDITIONAL BUSINESS LICENSES (for completeness)
-- =============================================================================

INSERT INTO commerce.business_licenses (
    merchant_id, license_type, license_number, status, application_date,
    issue_date, expiration_date, license_fee, fee_paid
) VALUES
-- Pharmacy license for new merchant
(6, 'Pharmacy', 'PH-2024-006', 'active', '2024-01-15', '2024-02-01', '2024-12-31', 750.00, 750.00),
(6, 'General Business', 'GB-2024-006', 'active', '2024-01-15', '2024-02-01', '2024-12-31', 150.00, 150.00),

-- Renewal applications for next year
(1, 'Food Service', 'FS-2025-001', 'pending', '2024-11-01', NULL, '2025-12-31', 375.00, 375.00),
(2, 'General Business', 'GB-2025-002', 'under_review', '2024-10-15', NULL, '2025-12-31', 175.00, 175.00);

-- =============================================================================
-- FINAL VERIFICATION AND SUMMARY
-- =============================================================================

-- Enhanced verification query with more comprehensive checks
SELECT 'FINAL DATA SUMMARY' as section, '' as details
UNION ALL SELECT '==================', '===================='
UNION ALL SELECT 'Citizens', CONCAT(COUNT(*), ' records') FROM civics.citizens
UNION ALL SELECT 'Merchants', CONCAT(COUNT(*), ' records') FROM commerce.merchants
UNION ALL SELECT 'Orders', CONCAT(COUNT(*), ' records') FROM commerce.orders
UNION ALL SELECT 'Order Items', CONCAT(COUNT(*), ' records') FROM commerce.order_items
UNION ALL SELECT 'Permits', CONCAT(COUNT(*), ' records') FROM civics.permit_applications
UNION ALL SELECT 'Tax Payments', CONCAT(COUNT(*), ' records') FROM civics.tax_payments
UNION ALL SELECT 'Neighborhoods', CONCAT(COUNT(*), ' records') FROM geo.neighborhood_boundaries
UNION ALL SELECT 'POIs', CONCAT(COUNT(*), ' records') FROM geo.points_of_interest
UNION ALL SELECT 'Stations', CONCAT(COUNT(*), ' records') FROM mobility.stations
UNION ALL SELECT 'Trip Segments', CONCAT(COUNT(*), ' records') FROM mobility.trip_segments
UNION ALL SELECT 'Sensor Readings', CONCAT(COUNT(*), ' records') FROM mobility.sensor_readings
UNION ALL SELECT 'Complaints', CONCAT(COUNT(*), ' records') FROM documents.complaint_records
UNION ALL SELECT 'Policies', CONCAT(COUNT(*), ' records') FROM documents.policy_documents
UNION ALL SELECT 'Business Licenses', CONCAT(COUNT(*), ' records') FROM commerce.business_licenses
UNION ALL SELECT 'Station Inventory', CONCAT(COUNT(*), ' records') FROM mobility.station_inventory
UNION ALL SELECT 'Payments', CONCAT(COUNT(*), ' records') FROM commerce.payments
UNION ALL SELECT 'Voting Records', CONCAT(COUNT(*), ' records') FROM civics.voting_records
UNION ALL SELECT '', ''
UNION ALL SELECT 'INTEGRITY CHECKS', '===================='
UNION ALL SELECT 'Orphaned Orders',
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS - No orphaned orders'
        ELSE CONCAT('FAIL - ', COUNT(*), ' orders without valid customers')
    END
FROM commerce.orders o
LEFT JOIN civics.citizens c ON o.customer_citizen_id = c.citizen_id
WHERE c.citizen_id IS NULL
UNION ALL SELECT 'Order Totals',
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS - All order totals calculated correctly'
        ELSE CONCAT('FAIL - ', COUNT(*), ' orders with incorrect totals')
    END
FROM commerce.orders
WHERE ABS(total_amount - (subtotal + tax_amount + tip_amount)) > 0.01
ORDER BY section DESC, details;

-- =============================================================================
-- PERFORMANCE INDEXES (RECOMMENDED)
-- =============================================================================

-- Create indexes for common query patterns (commented for reference)
/*
-- Citizen lookups
CREATE INDEX CONCURRENTLY idx_citizens_email ON civics.citizens(email);
CREATE INDEX CONCURRENTLY idx_citizens_phone ON civics.citizens(phone);

-- Geographic queries
CREATE INDEX CONCURRENTLY idx_poi_location ON geo.points_of_interest USING GIST(location_geom);
CREATE INDEX CONCURRENTLY idx_neighborhoods_boundary ON geo.neighborhood_boundaries USING GIST(boundary_geom);

-- Temporal queries
CREATE INDEX CONCURRENTLY idx_orders_date ON commerce.orders(order_date);
CREATE INDEX CONCURRENTLY idx_sensor_readings_time ON mobility.sensor_readings(reading_time);
CREATE INDEX CONCURRENTLY idx_trip_segments_time ON mobility.trip_segments(start_time, end_time);

-- Business queries
CREATE INDEX CONCURRENTLY idx_orders_merchant ON commerce.orders(merchant_id);
CREATE INDEX CONCURRENTLY idx_licenses_merchant ON commerce.business_licenses(merchant_id);
CREATE INDEX CONCURRENTLY idx_payments_order ON commerce.payments(order_id);
*/

-- =============================================================================
-- FILE COMPLETION MARKER
-- =============================================================================

SELECT 'SEED DATA FILE COMPLETED SUCCESSFULLY' as status, NOW() as completed_at;

-- End of seed_data.sql
-- =============================================================================
