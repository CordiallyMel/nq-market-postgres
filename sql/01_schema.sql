-- NQ market-data portfolio schema
-- PostgreSQL 16+; tested on PostgreSQL 18.
--
-- This file creates the base table only.  The analytical views are deliberately
-- materialized in 02_views.sql after the data load: building a five-minute view
-- over 3.3 million raw rows once is fast, while recomputing it inside every
-- downstream query is not.

CREATE SCHEMA IF NOT EXISTS nq;

DROP TABLE IF EXISTS nq.bars_1m CASCADE;

CREATE TABLE nq.bars_1m (
    symbol       varchar(12)   NOT NULL,
    ts           timestamptz   NOT NULL,
    open         numeric(14,2) NOT NULL,
    high         numeric(14,2) NOT NULL,
    low          numeric(14,2) NOT NULL,
    close        numeric(14,2) NOT NULL,
    volume       bigint        NOT NULL DEFAULT 0,
    trades       integer,
    session_date date          NOT NULL,
    is_rth       boolean       NOT NULL,
    PRIMARY KEY (symbol, ts),
    CHECK (high >= low),
    CHECK (open >= low AND open <= high),
    CHECK (close >= low AND close <= high)
);

CREATE INDEX bars_1m_session_idx
    ON nq.bars_1m (session_date, ts);

CREATE INDEX bars_1m_rth_idx
    ON nq.bars_1m (session_date, ts)
    WHERE is_rth;
