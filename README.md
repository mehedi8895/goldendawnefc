# Golden Dawn eFC
Pure HTML5 + CSS3 + Vanilla JS frontend with Supabase Auth/Postgres/Realtime.

1. Create Supabase project.
2. Run `supabase/schema.sql` in SQL Editor.
3. Register the intended owner account, then approve/promote it once from a trusted SQL/admin context.
4. Put the project URL and publishable/anon key in `js/config.js`.
5. Deploy this folder as static hosting.
6. Configure Supabase Auth redirect URLs to your deployed domain.

Never expose a service-role key in frontend code. Privileged approval/staff/tournament-generation operations should use authenticated Edge Functions with the service-role key kept server-side.
