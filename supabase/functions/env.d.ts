/**
 * تعريفات Deno لـ Supabase Edge Functions — يزيل خطأ Deno.serve في Cursor/VS Code
 * (التشغيل الفعلي على Deno Edge Runtime عند النشر)
 */
declare namespace Deno {
  function serve(
    handler: (request: Request) => Response | Promise<Response>,
    options?: {
      port?: number;
      hostname?: string;
      signal?: AbortSignal;
      onListen?: (params: { hostname: string; port: number }) => void;
    }
  ): { shutdown: () => Promise<void> };

  namespace env {
    function get(key: string): string | undefined;
  }
}
