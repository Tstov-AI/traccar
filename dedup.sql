DELETE FROM tc_positions p1
WHERE EXISTS (
    SELECT 1 FROM tc_positions p2
    WHERE p1.deviceid = p2.deviceid
      AND p1.fixtime = p2.fixtime
      AND p1.id > p2.id
);
