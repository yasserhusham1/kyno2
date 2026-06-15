-- ============================================================
-- KYNO 054 — Realtime على جدول الإجازات للمزامنة الفورية
-- ============================================================

ALTER TABLE IF EXISTS public.leaves REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.leaves;
    EXCEPTION
      WHEN duplicate_object THEN NULL;
    END;
  END IF;
END $$;
