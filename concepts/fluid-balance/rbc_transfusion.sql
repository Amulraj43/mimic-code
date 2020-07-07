-- --------------------------------------------------------
-- Title: Retrieves instances of RBC transfusions
-- Notes: this query does not specify a schema. To run it on your local
-- MIMIC schema, run the following command:
--  SET SEARCH_PATH TO public, mimiciii;
-- Where "mimiciii" is the name of your schema, and may be different.
-- This will create the table on the "public" schema.
-- --------------------------------------------------------

DROP materialized VIEW IF EXISTS rbc_transfusion CASCADE; 
CREATE materialized VIEW rbc_transfusion AS
with raw_rbc as (
  SELECT
      CASE
        WHEN amount IS NOT NULL THEN amount
        WHEN stopped IS NOT NULL THEN 0
        -- impute 375 mL when unit is not documented
        ELSE 375
      END AS amount
    , amountuom
    , icustay_id
    , charttime
  FROM inputevents_cv
  WHERE itemid IN
  (
    30179,  -- PRBC's
    30001,  -- Packed RBC's
    30004   -- Washed PRBC's
  )
  UNION ALL
  SELECT amount
    , amountuom
    , icustay_id
    , endtime AS charttime
  FROM inputevents_mv
  WHERE itemid in
  (
    225168   -- Packed Red Blood Cells
  )
  AND amount > 0
),
pre_icu_rbc as (
  SELECT
    sum(amount) as amount, icustay_id
  FROM inputevents_cv
  WHERE itemid IN (
    42324,  -- er prbc
    42588,  -- VICU PRBC
    42239,  -- CC7 PRBC
    46407,  -- ED PRBC
    46612,  -- E.R. prbc
    46124,  -- er in prbc
    42740   -- prbc in er
  )
  AND amount > 0
  GROUP BY icustay_id
  UNION ALL
  SELECT
    sum(amount) as amount, icustay_id
  FROM inputevents_mv
  WHERE itemid IN (
    227070  -- PACU Packed RBC Intake
  )
  AND amount > 0
  GROUP BY icustay_id
),
cumulative AS (
  SELECT
    sum(amount) over (PARTITION BY icustay_id ORDER BY charttime DESC) AS amount
    , amountuom
    , icustay_id
    , charttime
    , lag(charttime) over (PARTITION BY icustay_id ORDER BY charttime ASC) - charttime AS delta
  FROM raw_ffp
)
-- We consider any transfusions started within 1 hr of the last one
-- to be part of the same event
SELECT
    cm.icustay_id
  , cm.charttime
  , cm.amount - CASE
      WHEN ROW_NUMBER() OVER w = 1 THEN 0
      ELSE lag(cm.amount) OVER w
    END AS amount
  , cm.amount + CASE
      WHEN pre.amount IS NULL THEN 0
      ELSE pre.amount
    END AS totalamount
  , cm.amountuom
FROM cumulative AS cm
LEFT JOIN pre_icu_ffp AS pre
  USING (icustay_id)
WHERE delta IS NULL OR delta < CAST('-1 hour' AS INTERVAL)
WINDOW w AS (PARTITION BY cm.icustay_id ORDER BY cm.charttime DESC)
ORDER BY icustay_id, charttime;
