CREATE TABLE `session` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `parent_id` text,
          `slug` text NOT NULL,
          `directory` text NOT NULL,
          `title` text NOT NULL,
          `version` text NOT NULL,
          `share_url` text,
          `summary_additions` integer,
          `summary_deletions` integer,
          `summary_files` integer,
          `summary_diffs` text,
          `revert` text,
          `permission` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_compacting` integer,
          `time_archived` integer, `workspace_id` text, `path` text, `agent` text, `model` text, `cost` real DEFAULT 0 NOT NULL, `tokens_input` integer DEFAULT 0 NOT NULL, `tokens_output` integer DEFAULT 0 NOT NULL, `tokens_reasoning` integer DEFAULT 0 NOT NULL, `tokens_cache_read` integer DEFAULT 0 NOT NULL, `tokens_cache_write` integer DEFAULT 0 NOT NULL, `metadata` text
        );
CREATE TABLE `message` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `part` (
          `id` text PRIMARY KEY,
          `message_id` text NOT NULL,
          `session_id` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
        );
INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, permission, time_created, time_updated) VALUES
  ('ses_root1', 'prj_1', NULL, 'quick-fern', '/Users/test/web', 'Fix flaky login test', '1.18.3', NULL, 1768000000000, 1768000060000),
  ('ses_child1', 'prj_1', 'ses_root1', 'quiet-fern', '/Users/test/web', 'Explore auth (@explore subagent)', '1.18.3', '[{"permission":"todowrite","pattern":"*","action":"deny"},{"permission":"task","pattern":"*","action":"deny"}]', 1768000020000, 1768000050000),
  ('ses_run1', 'prj_1', NULL, 'brisk-owl', '/Users/test/web', 'New session - 2026-01-10T00:00:00.000Z', '1.18.3', '[{"permission":"question","pattern":"*","action":"deny"},{"permission":"plan_enter","pattern":"*","action":"deny"},{"permission":"plan_exit","pattern":"*","action":"deny"}]', 1768100000000, 1768100005000),
  ('ses_new1', 'prj_1', NULL, 'calm-owl', '/Users/test/web', 'New session - 2026-01-12T00:00:00.000Z', '1.18.3', NULL, 1768200000000, 1768200005000);
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
  ('msg_1', 'ses_root1', 1768000001000, 1768000001000, '{"role":"user","time":{"created":1768000001000},"agent":"build"}'),
  ('msg_2', 'ses_root1', 1768000002000, 1768000040000, '{"role":"assistant","time":{"created":1768000002000},"agent":"build"}'),
  ('msg_3', 'ses_child1', 1768000021000, 1768000021000, '{"role":"user","time":{"created":1768000021000},"agent":"explore"}'),
  ('msg_4', 'ses_child1', 1768000022000, 1768000050000, '{"role":"assistant","time":{"created":1768000022000},"agent":"explore"}'),
  ('msg_5', 'ses_run1', 1768100001000, 1768100001000, '{"role":"user","time":{"created":1768100001000},"agent":"build"}'),
  ('msg_6', 'ses_new1', 1768200001000, 1768200001000, '{"role":"user","time":{"created":1768200001000},"agent":"build"}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES
  ('prt_01', 'msg_1', 'ses_root1', 1768000001000, 1768000001000, '{"type":"text","text":"<system-reminder>Note: the user opened a file hidden-synthetic-marker</system-reminder>","synthetic":true}'),
  ('prt_02', 'msg_1', 'ses_root1', 1768000001001, 1768000001001, '{"type":"text","text":"Why does the login test flake? ferret-prompt"}'),
  ('prt_03', 'msg_2', 'ses_root1', 1768000003000, 1768000004000, '{"type":"reasoning","text":"hidden-reasoning-marker","time":{"start":1768000003000,"end":1768000004000}}'),
  ('prt_04', 'msg_2', 'ses_root1', 1768000005000, 1768000006000, '{"type":"tool","tool":"bash","state":{"status":"completed","output":"hidden-tool-output-marker"}}'),
  ('prt_05', 'msg_2', 'ses_root1', 1768000007000, 1768000008000, '{"type":"text","text":"Because of a race in the fixture. heron-reply","time":{"start":1768000007000,"end":1768000008000}}'),
  ('prt_06', 'msg_2', 'ses_root1', 1768000009000, 1768000009500, '{"type":"text","text":"streaming-partial-marker","time":{"start":1768000009000}}'),
  ('prt_07', 'msg_3', 'ses_child1', 1768000021000, 1768000021000, '{"type":"text","text":"Look at the auth module. child-briefing-marker"}'),
  ('prt_08', 'msg_4', 'ses_child1', 1768000030000, 1768000031000, '{"type":"text","text":"The auth module is fine. child-finding-marker","time":{"start":1768000030000,"end":1768000031000}}'),
  ('prt_09', 'msg_5', 'ses_run1', 1768100001000, 1768100001000, '{"type":"text","text":"Reply with ok. oneshot-opencode-marker"}'),
  ('prt_10', 'msg_6', 'ses_new1', 1768200001000, 1768200001000, '{"type":"text","text":"Plan the migration. gecko-prompt"}');
