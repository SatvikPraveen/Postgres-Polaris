# Dataset card: Polaris City (synthetic)

Polaris City is a fully synthetic, deterministic urban dataset generated inside PostgreSQL by `sql/03_dml_queries/seed_data.sql`. It is built so that every exercise, benchmark and analysis in this repository has a known, reproducible answer.

| | |
|---|---|
| Generator | `seed_data.sql`, version 2.1.0, recorded in `meta.dataset.generator_version` |
| Parameters | `scale` (default 1) and `seed` (default 42) |
| Reference time | `meta.as_of()` = 2025-12-31 23:59:59 UTC. Nothing in the data happens after it. |
| Size at scale 1 | about 420,000 rows across 18 tables, about 13 s to generate |
| Personal data | None. All names, addresses and identifiers are synthetic. |
| License | MIT, same as the repository |

## Contents at scale 1, seed 42

| Domain | Table | Rows | Notes |
|---|---|---:|---|
| Civics | `civics.citizens` | 10,000 | age 18 to 90, home location as a point, zip code identifies the neighbourhood |
| | `civics.permit_applications` | 3,000 | three years of history, statuses consistent with `as_of` |
| | `civics.tax_payments` | 25,815 | property and vehicle tax for 2023 to 2025 |
| | `civics.voting_records` | 11,268 | four elections, logistic turnout model |
| Commerce | `commerce.merchants` | 500 | seven business types, log-normal revenue |
| | `commerce.business_licenses` | 679 | renewals never overlap (exclusion constraint) |
| | `commerce.orders` | 50,000 | 52 weeks, weekly and diurnal seasonality, growth |
| | `commerce.order_items` | 112,458 | log-normal prices by business type |
| | `commerce.payments` | 48,734 | about 1.5% failed first attempts with a retry |
| Mobility | `mobility.stations` | 150 | bus, rail corridor, bike share, scooter, park and ride, EV |
| | `mobility.station_inventory` | 43,200 | hourly dock counts for 30 days |
| | `mobility.trip_segments` | 51,908 | 180 days, eight modes, multimodal access legs |
| | `mobility.sensor_readings` | 103,369 | 48 sensors, hourly for 90 days, with gaps |
| Geography | `geo.neighborhood_boundaries` | 24 | 6 x 4 grid covering 79.6 km² around 32.98 N, 96.80 W |
| | `geo.road_segments` | 1,067 | regular street grid usable as a routing graph |
| | `geo.points_of_interest` | 600 | 15 categories |
| Documents | `documents.complaint_records` | 5,000 | spatial hotspots, free text for full-text search |
| | `documents.policy_documents` | 135 | JSONB sections, about 20% have a superseding v2.0 |
| Provenance | `meta.ground_truth` | 2,755 | labelled anomalies |

People and transactions scale linearly with `scale`. Geography, stations and documents do not.

## How it is generated

**Counter-based randomness.** Every random draw is `synth.u(key, stream)`: 53 bits of `hashint8extended(key, seed * 1000003 + stream)` mapped to [0, 1). Normal, exponential, Zipf and categorical variates are derived from it in `synth.*`. Because a draw depends only on its key and stream, never on execution order, the output is identical regardless of join strategy, `work_mem` or parallelism. Plain `random()` with `setseed()` cannot guarantee that.

**Stable keys.** Every insert has an explicit `ORDER BY`, so surrogate keys are assigned in the same order on every run.

**Latent structure.**
- Each neighbourhood has a standardised income score, `income_z`. It follows a north-west to south-east gradient plus noise and drives median income, property values, turnout and complaint resolution time.
- Population density and commercial intensity are separate latent fields. They decide where residents, merchants and stations go.
- Order times combine a day-of-week profile, a lunch and dinner diurnal profile and annual growth. Trip times use weekday commute peaks and a flatter weekend profile.
- Sensor values combine daily, weekly and annual sinusoids with commute-driven load and noise.

## Planted effects

These parameters are part of the generative model and are stored in `meta.planted_effects`. A correct analysis should recover them within sampling error.

| Effect | True value | Recovered at scale 1, seed 42 | Where it is estimated |
|---|---:|---:|---|
| Complaint resolution time vs neighbourhood income (log-multiplier per SD) | -0.25 | -0.258 (SE 0.009) | `16_capstones/citywide_analytics_dashboard.sql` |
| Peak vs off-peak mean transit delay | 3.0 | 3.06 | `03_dml_queries/practice_selects.sql`, `examples/quick_demo.sql` |
| Zipf exponent of orders per merchant | 1.10 | 1.05 to 1.07 | `examples/analytics_showcase.sql` |
| Peak speed factor for road modes | 0.70 | | trip speeds by hour |
| Turnout slope per year of age (logit) | 0.035 | | voting records joined to citizens |
| Turnout slope per SD of income (logit) | 0.40 | | as above |
| Share of orders with injected 15 to 25x amounts | 0.002 | 103 labelled | `16_capstones/anomaly_detection_patterns.sql` |
| Sensor point anomalies (spikes, dropouts) | 0.006 | 614 labelled | as above |
| Level-shift windows per sensor | 3 | 2,038 labelled readings | as above |

A pooled estimate of the resolution gradient that ignores complaint category gives about -0.18. The capstone shows this as a worked example of omitted-variable bias.

## Ground truth

`meta.ground_truth(entity, entity_id, label, detail)` lists every injected anomaly:

| Entity | Label | Count | Definition |
|---|---|---:|---|
| `mobility.sensor_readings` | `spike` | 386 | value raised by about six noise standard deviations |
| | `dropout` | 228 | value 0, quality score 0.25 |
| | `level_shift` | 2,038 | every reading inside a 6 to 24 hour window where the value is multiplied by 1.4 |
| `commerce.orders` | `order_amount_outlier` | 103 | item prices multiplied by 15 to 25 |

Detectors in module 16 report precision, recall and F1 against these labels.

## Consistency guarantees

The test suite asserts all of the following:
- Every row satisfies the module-02 constraints: CHECK, exclusion, foreign key, unique and NOT NULL.
- Money adds up: `total = subtotal + tax + tip` and `line_total = unit_price * quantity`.
- No event lies after `meta.as_of()`. Statuses agree with dates; for example, an approval date in the future becomes `pending`.
- Neighbourhood polygons tile the city without overlap, and every complaint point lies inside its neighbourhood.
- `population_estimate` equals the number of citizens in the neighbourhood.

## Limitations

- **Geography is stylised.** It is a regular grid, not a real street network. Distances are realistic in scale, but topology is simpler than a real city.
- **Independence.** Most entities are independent given the latent fields. For example, citizens' orders are not tied to where they live, and trips are not linked to orders.
- **Text is templated.** Complaint and policy text comes from templates. It is good for full-text search mechanics but not for language modelling.
- **Recovery is approximate.** Effects are recovered approximately at scale 1. The Zipf estimate is biased slightly low by the bounded, discretised sampler. Larger `scale` narrows the confidence intervals.
- **Float determinism across platforms.** Floating-point functions such as `exp` and `ln` come from the platform math library. Identical output is verified within one platform and across PostgreSQL 17 and 18. Across CPU architectures, a value that sits exactly on a rounding boundary could in principle differ.

## Citing

See [`CITATION.cff`](../CITATION.cff). When reporting results, quote `generator_version`, `scale` and `seed` from `meta.dataset`, plus the output of `make reproduce`.
