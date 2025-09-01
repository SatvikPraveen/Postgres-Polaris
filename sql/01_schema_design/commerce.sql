-- File: sql/01_schema_design/commerce.sql
-- Purpose: Commerce schema for merchants, orders, payments, business licenses

-- =============================================================================
-- ENUMS AND TYPES
-- =============================================================================

CREATE TYPE commerce.business_type AS ENUM ('restaurant', 'retail', 'service', 'manufacturing', 'technology', 'healthcare', 'other');
CREATE TYPE commerce.license_status AS ENUM ('active', 'pending', 'expired', 'suspended', 'revoked');
CREATE TYPE commerce.order_status AS ENUM ('pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded');
CREATE TYPE commerce.payment_method AS ENUM ('cash', 'credit_card', 'debit_card', 'bank_transfer', 'digital_wallet', 'check');
CREATE TYPE commerce.payment_status AS ENUM ('pending', 'completed', 'failed', 'refunded', 'disputed');

-- =============================================================================
-- MERCHANTS
-- =============================================================================

CREATE TABLE commerce.merchants (
    merchant_id BIGSERIAL PRIMARY KEY,

    -- Business Information
    business_name VARCHAR(200) NOT NULL,
    legal_name VARCHAR(200), -- For corporations different from DBA
    tax_id VARCHAR(20) UNIQUE NOT NULL, -- EIN or SSN

    -- Owner/Contact
    owner_citizen_id BIGINT REFERENCES civics.citizens(citizen_id),
    contact_email VARCHAR(255) NOT NULL,
    contact_phone VARCHAR(20),

    -- Business Address
    business_address VARCHAR(500) NOT NULL,
    city VARCHAR(100) NOT NULL DEFAULT 'Polaris City',
    state VARCHAR(2) NOT NULL DEFAULT 'TX',
    zip_code VARCHAR(10) NOT NULL,

    -- Business Details
    business_type commerce.business_type NOT NULL,
    industry_code VARCHAR(10), -- NAICS code
    website VARCHAR(500),
    description TEXT,

    -- Metrics
    annual_revenue NUMERIC(15,2),
    employee_count INTEGER,

    -- Status
    is_active BOOLEAN DEFAULT true NOT NULL,
    registration_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE commerce.merchants IS
'Registered businesses operating within city limits.
Business Rules: tax_id must be unique, all merchants must have valid business license';

-- =============================================================================
-- BUSINESS LICENSES
-- =============================================================================

CREATE TABLE commerce.business_licenses (
    license_id BIGSERIAL PRIMARY KEY,
    merchant_id BIGINT NOT NULL REFERENCES commerce.merchants(merchant_id),

    -- License Details
    license_type VARCHAR(100) NOT NULL, -- General Business, Food Service, Liquor, etc.
    license_number VARCHAR(50) UNIQUE NOT NULL,

    -- Status and Dates
    status commerce.license_status DEFAULT 'pending' NOT NULL,
    application_date DATE NOT NULL DEFAULT CURRENT_DATE,
    issue_date DATE,
    expiration_date DATE,
    renewal_date DATE,

    -- Financial
    license_fee NUMERIC(10,2) NOT NULL,
    fee_paid NUMERIC(10,2) NOT NULL DEFAULT 0.00,

    -- Compliance
    inspection_required BOOLEAN DEFAULT false,
    last_inspection_date DATE,
    next_inspection_due DATE,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE commerce.business_licenses IS
'Business license tracking with renewal and inspection management.
Business Rules: license_number unique, fee_paid <= license_fee';

-- =============================================================================
-- ORDERS
-- =============================================================================

CREATE TABLE commerce.orders (
    order_id BIGSERIAL PRIMARY KEY,
    merchant_id BIGINT NOT NULL REFERENCES commerce.merchants(merchant_id),
    customer_citizen_id BIGINT REFERENCES civics.citizens(citizen_id), -- NULL for walk-ins

    -- Order Details
    order_number VARCHAR(50) UNIQUE NOT NULL,
    order_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,

    -- Status
    status commerce.order_status DEFAULT 'pending' NOT NULL,

    -- Financial Summary
    subtotal NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    tip_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00,

    -- Delivery Information
    delivery_address VARCHAR(500),
    delivery_instructions TEXT,
    estimated_delivery TIMESTAMPTZ,
    actual_delivery TIMESTAMPTZ,

    -- Notes
    order_notes TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE commerce.orders IS
'Customer orders from registered merchants.
Business Rules: total_amount = subtotal + tax_amount + tip_amount';

-- =============================================================================
-- ORDER ITEMS
-- =============================================================================

CREATE TABLE commerce.order_items (
    item_id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES commerce.orders(order_id) ON DELETE CASCADE,

    -- Item Details
    item_name VARCHAR(200) NOT NULL,
    item_description TEXT,
    sku VARCHAR(100), -- Stock Keeping Unit

    -- Pricing
    unit_price NUMERIC(10,2) NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1,
    line_total NUMERIC(12,2) NOT NULL, -- unit_price * quantity

    -- Modifiers/Options
    item_options JSONB, -- Size, color, customizations, etc.

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE commerce.order_items IS
'Individual items within customer orders.
Business Rules: quantity > 0, line_total = unit_price * quantity';

-- =============================================================================
-- PAYMENTS
-- =============================================================================

CREATE TABLE commerce.payments (
    payment_id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL REFERENCES commerce.orders(order_id),

    -- Payment Details
    payment_method commerce.payment_method NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    currency CHAR(3) DEFAULT 'USD' NOT NULL,

    -- Status and Processing
    status commerce.payment_status DEFAULT 'pending' NOT NULL,
    transaction_id VARCHAR(100), -- External payment processor ID
    processor VARCHAR(50), -- Stripe, Square, etc.

    -- Timestamps
    payment_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    processed_at TIMESTAMPTZ,

    -- Reference Information
    reference_number VARCHAR(100),
    receipt_number VARCHAR(100),

    -- Metadata
    processor_response JSONB,
    failure_reason TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE commerce.payments IS
'Payment transactions for orders with processor integration tracking.
Business Rules: amount > 0, successful payments must have processed_at';

-- =============================================================================
-- INDEXES FOR PERFORMANCE
-- =============================================================================

-- Merchants indexes
CREATE INDEX idx_merchants_business_name ON commerce.merchants(business_name);
CREATE INDEX idx_merchants_type ON commerce.merchants(business_type);
CREATE INDEX idx_merchants_owner ON commerce.merchants(owner_citizen_id);
CREATE INDEX idx_merchants_zip ON commerce.merchants(zip_code);
CREATE INDEX idx_merchants_active ON commerce.merchants(is_active) WHERE is_active = true;

-- License indexes
CREATE INDEX idx_licenses_merchant ON commerce.business_licenses(merchant_id);
CREATE INDEX idx_licenses_status ON commerce.business_licenses(status);
CREATE INDEX idx_licenses_expiration ON commerce.business_licenses(expiration_date)
    WHERE status = 'active';
CREATE INDEX idx_licenses_inspection ON commerce.business_licenses(next_inspection_due)
    WHERE inspection_required = true;

-- Orders indexes
CREATE INDEX idx_orders_merchant ON commerce.orders(merchant_id);
CREATE INDEX idx_orders_customer ON commerce.orders(customer_citizen_id);
CREATE INDEX idx_orders_date ON commerce.orders(order_date);
CREATE INDEX idx_orders_status ON commerce.orders(status);
CREATE INDEX idx_orders_delivery_date ON commerce.orders(estimated_delivery)
    WHERE estimated_delivery IS NOT NULL;

-- Order items indexes
CREATE INDEX idx_order_items_order ON commerce.order_items(order_id);
CREATE INDEX idx_order_items_sku ON commerce.order_items(sku) WHERE sku IS NOT NULL;

-- Payments indexes
CREATE INDEX idx_payments_order ON commerce.payments(order_id);
CREATE INDEX idx_payments_status ON commerce.payments(status);
CREATE INDEX idx_payments_date ON commerce.payments(payment_date);
CREATE INDEX idx_payments_method ON commerce.payments(payment_method);
CREATE INDEX idx_payments_transaction ON commerce.payments(transaction_id) WHERE transaction_id IS NOT NULL;

-- =============================================================================
-- TRIGGERS FOR CALCULATED FIELDS
-- =============================================================================

-- Update order totals when items change
CREATE OR REPLACE FUNCTION commerce.update_order_totals()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE commerce.orders
    SET
        subtotal = (
            SELECT COALESCE(SUM(line_total), 0)
            FROM commerce.order_items
            WHERE order_id = COALESCE(NEW.order_id, OLD.order_id)
        ),
        updated_at = NOW()
    WHERE order_id = COALESCE(NEW.order_id, OLD.order_id);

    -- Recalculate total_amount (assuming tax is 8.25%)
    UPDATE commerce.orders
    SET
        tax_amount = subtotal * 0.0825,
        total_amount = subtotal + (subtotal * 0.0825) + tip_amount,
        updated_at = NOW()
    WHERE order_id = COALESCE(NEW.order_id, OLD.order_id);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_items_totals
    AFTER INSERT OR UPDATE OR DELETE ON commerce.order_items
    FOR EACH ROW EXECUTE FUNCTION commerce.update_order_totals();

COMMENT ON FUNCTION commerce.update_order_totals() IS
'Automatically recalculates order subtotal, tax, and total when items change';
