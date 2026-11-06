-- 02_load_raw.sql
-- Loads all downloaded sample years into raw.orig / raw.perf.
-- Uses \copy, so it must run through psql, FROM THE REPO ROOT:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/00_load/02_load_raw.sql
-- QUOTE E'\b' switches off quote handling, so a stray " inside a field can't break the load.
-- The vintage of each loan is encoded in loan_seq_no (e.g. F22Q1... = 2022 Q1), so no source column is needed.

TRUNCATE raw.orig;
TRUNCATE raw.perf;

-- 2006
\copy raw.orig FROM 'data/raw/sample_2006/sample_orig_2006.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2006/sample_perf_2006.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2007
\copy raw.orig FROM 'data/raw/sample_2007/sample_orig_2007.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2007/sample_perf_2007.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2008
\copy raw.orig FROM 'data/raw/sample_2008/sample_orig_2008.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2008/sample_perf_2008.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2016
\copy raw.orig FROM 'data/raw/sample_2016/sample_orig_2016.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2016/sample_perf_2016.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2017
\copy raw.orig FROM 'data/raw/sample_2017/sample_orig_2017.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2017/sample_perf_2017.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2018
\copy raw.orig FROM 'data/raw/sample_2018/sample_orig_2018.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2018/sample_perf_2018.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2019
\copy raw.orig FROM 'data/raw/sample_2019/sample_orig_2019.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2019/sample_perf_2019.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2020
\copy raw.orig FROM 'data/raw/sample_2020/sample_orig_2020.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2020/sample_perf_2020.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2021
\copy raw.orig FROM 'data/raw/sample_2021/sample_orig_2021.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2021/sample_perf_2021.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2022
\copy raw.orig FROM 'data/raw/sample_2022/sample_orig_2022.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2022/sample_perf_2022.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2023
\copy raw.orig FROM 'data/raw/sample_2023/sample_orig_2023.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2023/sample_perf_2023.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2024
\copy raw.orig FROM 'data/raw/sample_2024/sample_orig_2024.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2024/sample_perf_2024.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- 2025
\copy raw.orig FROM 'data/raw/sample_2025/sample_orig_2025.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')
\copy raw.perf FROM 'data/raw/sample_2025/sample_perf_2025.txt' WITH (FORMAT csv, DELIMITER '|', QUOTE E'\b')

-- Checks: loans per vintage (expect ~50,000 per full year; 2025 may be partial)
SELECT '20' || substring(loan_seq_no, 2, 2) AS vintage, count(*) AS loans
FROM raw.orig
GROUP BY 1
ORDER BY 1;

-- Performance rows and distinct loans per vintage
SELECT '20' || substring(loan_seq_no, 2, 2) AS vintage,
       count(*)                    AS perf_rows,
       count(DISTINCT loan_seq_no) AS loans
FROM raw.perf
GROUP BY 1
ORDER BY 1;