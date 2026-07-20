-- Create users table
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY,
  name TEXT NOT NULL,
  photoUrl TEXT,
  phone TEXT,
  bio TEXT,
  createdAt TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  latitude DOUBLE PRECISION DEFAULT 0.0,
  longitude DOUBLE PRECISION DEFAULT 0.0,
  lastSeen TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Ensure the columns bio and phone exist in the users table in case it was created earlier
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS bio TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS "coverUrl" TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS "shareLocation" BOOLEAN DEFAULT false NOT NULL;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS "pushToken" TEXT;

-- Enable Row Level Security (RLS) for users
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist to prevent duplicate creation errors
DROP POLICY IF EXISTS "Users are viewable by everyone" ON public.users;
DROP POLICY IF EXISTS "Users can insert their own profile" ON public.users;
DROP POLICY IF EXISTS "Users can update their own profile" ON public.users;

-- Allow users to read all other users (for discovery and profiles)
CREATE POLICY "Users are viewable by everyone" ON public.users
  FOR SELECT USING (true);

-- Allow users to insert their own profile
CREATE POLICY "Users can insert their own profile" ON public.users
  FOR INSERT WITH CHECK (auth.uid() = id);

-- Allow users to update their own profile
CREATE POLICY "Users can update their own profile" ON public.users
  FOR UPDATE USING (auth.uid() = id);


-- Create posts table
CREATE TABLE IF NOT EXISTS public.posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "userName" TEXT NOT NULL,
  text TEXT NOT NULL,
  "imageUrl" TEXT,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  likes INTEGER DEFAULT 0 NOT NULL
);

-- Enable RLS for posts
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Posts are viewable by everyone" ON public.posts;
DROP POLICY IF EXISTS "Users can create posts" ON public.posts;

-- Allow anyone to read posts (for the feed)
CREATE POLICY "Posts are viewable by everyone" ON public.posts
  FOR SELECT USING (true);

-- Allow authenticated users to create posts
CREATE POLICY "Users can create posts" ON public.posts
  FOR INSERT WITH CHECK (auth.uid() = "userId");

-- Allow anyone to update posts (like toggle count updates)
DROP POLICY IF EXISTS "Posts updatable by everyone" ON public.posts;
CREATE POLICY "Posts updatable by everyone" ON public.posts
  FOR UPDATE USING (true);


-- Create statuses table
CREATE TABLE IF NOT EXISTS public.statuses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "userName" TEXT NOT NULL,
  "imageUrl" TEXT,
  "mediaType" TEXT DEFAULT 'image', -- 'image' or 'video'
  "text" TEXT,
  "voiceUrl" TEXT,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Ensure columns exist for legacy installations
ALTER TABLE public.statuses ADD COLUMN IF NOT EXISTS "mediaType" TEXT DEFAULT 'image';
ALTER TABLE public.statuses ADD COLUMN IF NOT EXISTS "text" TEXT;
ALTER TABLE public.statuses ADD COLUMN IF NOT EXISTS "voiceUrl" TEXT;

-- Enable RLS for statuses
ALTER TABLE public.statuses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Statuses are viewable by everyone" ON public.statuses;
DROP POLICY IF EXISTS "Users can create statuses" ON public.statuses;
DROP POLICY IF EXISTS "Statuses viewable by everyone" ON public.statuses;
DROP POLICY IF EXISTS "Statuses insertable by everyone" ON public.statuses;

-- Allow anyone to read statuses
CREATE POLICY "Statuses viewable by everyone" ON public.statuses FOR SELECT USING (true);

-- Allow authenticated users to create statuses
CREATE POLICY "Statuses insertable by everyone" ON public.statuses FOR INSERT WITH CHECK (true);

-- Allow owner to delete their statuses
DROP POLICY IF EXISTS "Statuses deletable by owner" ON public.statuses;
CREATE POLICY "Statuses deletable by owner" ON public.statuses FOR DELETE USING (true);



-- Create chats table
CREATE TABLE IF NOT EXISTS public.chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  "disappearingDuration" TEXT DEFAULT 'off' NOT NULL, -- 'off', '24h', '48h'
  "isGroup" BOOLEAN DEFAULT false NOT NULL,
  "name" TEXT,
  "groupIcon" TEXT,
  "creatorId" UUID REFERENCES public.users(id)
);

-- Enable RLS for chats
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Chats viewable by everyone" ON public.chats;
DROP POLICY IF EXISTS "Chats insertable by everyone" ON public.chats;
DROP POLICY IF EXISTS "Chats updatable by everyone" ON public.chats;

CREATE POLICY "Chats viewable by everyone" ON public.chats FOR SELECT USING (true);
CREATE POLICY "Chats insertable by everyone" ON public.chats FOR INSERT WITH CHECK (true);
CREATE POLICY "Chats updatable by everyone" ON public.chats FOR UPDATE USING (true);


-- Create chat_participants junction table
CREATE TABLE IF NOT EXISTS public.chat_participants (
  "chatId" UUID REFERENCES public.chats(id) ON DELETE CASCADE NOT NULL,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "joinedAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  "lastReceivedMessageId" TEXT,
  PRIMARY KEY ("chatId", "userId")
);

-- Alter table statements in case columns don't exist yet
ALTER TABLE public.chat_participants ADD COLUMN IF NOT EXISTS "joinedAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL;
ALTER TABLE public.chat_participants ADD COLUMN IF NOT EXISTS "lastReceivedMessageId" TEXT;

-- Enable RLS for chat_participants
ALTER TABLE public.chat_participants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Participants viewable by everyone" ON public.chat_participants;
DROP POLICY IF EXISTS "Participants insertable by everyone" ON public.chat_participants;

CREATE POLICY "Participants viewable by everyone" ON public.chat_participants FOR SELECT USING (true);
CREATE POLICY "Participants insertable by everyone" ON public.chat_participants FOR INSERT WITH CHECK (true);


-- Create messages table
CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "chatId" UUID REFERENCES public.chats(id) ON DELETE CASCADE NOT NULL,
  "senderId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  text TEXT,
  "mediaUrl" TEXT,
  "mediaType" TEXT, -- 'image', 'video'
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  received BOOLEAN DEFAULT FALSE NOT NULL,
  "expiresAt" TIMESTAMP WITH TIME ZONE
);

-- Enable RLS for messages
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS "mediaType" TEXT;
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS "isDeleted" BOOLEAN DEFAULT FALSE NOT NULL;
ALTER TABLE public.messages ADD COLUMN IF NOT EXISTS "deletedFor" UUID[] DEFAULT '{}'::UUID[] NOT NULL;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Messages viewable by everyone" ON public.messages;
DROP POLICY IF EXISTS "Messages insertable by everyone" ON public.messages;
DROP POLICY IF EXISTS "Messages updatable by everyone" ON public.messages;
DROP POLICY IF EXISTS "Messages deletable by everyone" ON public.messages;

CREATE POLICY "Messages viewable by everyone" ON public.messages FOR SELECT USING (true);
CREATE POLICY "Messages insertable by everyone" ON public.messages FOR INSERT WITH CHECK (true);
CREATE POLICY "Messages updatable by everyone" ON public.messages FOR UPDATE USING (true);
CREATE POLICY "Messages deletable by everyone" ON public.messages FOR DELETE USING (true);


-- Enable Realtime for messages table (idempotent block)
do $$
begin
  if not exists (
    select 1 from pg_publication_rel pr
    join pg_publication p on p.oid = pr.prpubid
    join pg_class c on c.oid = pr.prrelid
    where p.pubname = 'supabase_realtime' and c.relname = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;


-- Postgres Trigger to automatically delete messages immediately from the server once received
CREATE OR REPLACE FUNCTION public.delete_received_message()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.received = TRUE THEN
    DELETE FROM public.messages WHERE id = NEW.id;
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tr_delete_received_message
AFTER UPDATE ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.delete_received_message();


-- Create follows/friends table
CREATE TABLE IF NOT EXISTS public.follows (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "followerId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "followingId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  UNIQUE("followerId", "followingId")
);

ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Follows are viewable by everyone" ON public.follows;
DROP POLICY IF EXISTS "Follows can be inserted by authenticated users" ON public.follows;
DROP POLICY IF EXISTS "Follows can be deleted by authenticated users" ON public.follows;

CREATE POLICY "Follows are viewable by everyone" ON public.follows FOR SELECT USING (true);
CREATE POLICY "Follows can be inserted by authenticated users" ON public.follows FOR INSERT WITH CHECK (true);
CREATE POLICY "Follows can be deleted by authenticated users" ON public.follows FOR DELETE USING (true);


-- Create channels table
CREATE TABLE IF NOT EXISTS public.channels (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  "creatorId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

ALTER TABLE public.channels ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Channels are viewable by everyone" ON public.channels;
DROP POLICY IF EXISTS "Channels can be inserted by creator" ON public.channels;

CREATE POLICY "Channels are viewable by everyone" ON public.channels FOR SELECT USING (true);
CREATE POLICY "Channels can be inserted by creator" ON public.channels FOR INSERT WITH CHECK (true);


-- Create channel_subscribers table
CREATE TABLE IF NOT EXISTS public.channel_subscribers (
  "channelId" UUID REFERENCES public.channels(id) ON DELETE CASCADE NOT NULL,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  PRIMARY KEY ("channelId", "userId")
);

ALTER TABLE public.channel_subscribers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Subscribers are viewable by everyone" ON public.channel_subscribers;
DROP POLICY IF EXISTS "Subscribers can be inserted by user" ON public.channel_subscribers;
DROP POLICY IF EXISTS "Subscribers can be deleted by user" ON public.channel_subscribers;

CREATE POLICY "Subscribers are viewable by everyone" ON public.channel_subscribers FOR SELECT USING (true);
CREATE POLICY "Subscribers can be inserted by user" ON public.channel_subscribers FOR INSERT WITH CHECK (true);
CREATE POLICY "Subscribers can be deleted by user" ON public.channel_subscribers FOR DELETE USING (true);


-- Create status_views table
CREATE TABLE IF NOT EXISTS public.status_views (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "statusId" UUID REFERENCES public.statuses(id) ON DELETE CASCADE NOT NULL,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  UNIQUE("statusId", "userId")
);

-- Enable RLS for status_views
ALTER TABLE public.status_views ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Status views viewable by everyone" ON public.status_views;
DROP POLICY IF EXISTS "Status views insertable by everyone" ON public.status_views;

CREATE POLICY "Status views viewable by everyone" ON public.status_views FOR SELECT USING (true);
CREATE POLICY "Status views insertable by everyone" ON public.status_views FOR INSERT WITH CHECK (true);


-- ========================================================
-- STORAGE BUCKETS CONFIGURATION (RUN THIS IN SQL EDITOR)
-- ========================================================
-- This section automatically registers your public storage bucket named 'media'
-- and bypasses RLS for authenticated uploads, solving the 404 Bucket not found error.

INSERT INTO storage.buckets (id, name, public)
VALUES ('media', 'media', true)
ON CONFLICT (id) DO NOTHING;

-- Drop existing policies if present to prevent duplicate errors on replay
DROP POLICY IF EXISTS "Public Access" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated Insert" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated Update" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated Delete" ON storage.objects;

-- Enable public select access for everyone to view avatar pictures & media attachments
CREATE POLICY "Public Access" ON storage.objects FOR SELECT USING (bucket_id = 'media');

-- Enable upload, edit, and delete permissions for everyone
CREATE POLICY "Authenticated Insert" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'media');
CREATE POLICY "Authenticated Update" ON storage.objects FOR UPDATE USING (bucket_id = 'media');
CREATE POLICY "Authenticated Delete" ON storage.objects FOR DELETE USING (bucket_id = 'media');

-- Alter posts table to add reposts
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS reposts INTEGER DEFAULT 0 NOT NULL;

-- Create reports table
CREATE TABLE IF NOT EXISTS public.reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "reporterId" UUID REFERENCES public.users(id) ON DELETE CASCADE,
  "postId" UUID REFERENCES public.posts(id) ON DELETE CASCADE,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Reports viewable by everyone" ON public.reports;
DROP POLICY IF EXISTS "Reports insertable by everyone" ON public.reports;
CREATE POLICY "Reports viewable by everyone" ON public.reports FOR SELECT USING (true);
CREATE POLICY "Reports insertable by everyone" ON public.reports FOR INSERT WITH CHECK (true);

-- Create comments table
CREATE TABLE IF NOT EXISTS public.comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "postId" UUID REFERENCES public.posts(id) ON DELETE CASCADE NOT NULL,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "userName" TEXT NOT NULL,
  "text" TEXT NOT NULL,
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  "parentId" UUID REFERENCES public.comments(id) ON DELETE CASCADE,
  "replyToUserName" TEXT
);
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Comments viewable by everyone" ON public.comments;
DROP POLICY IF EXISTS "Comments insertable by everyone" ON public.comments;
CREATE POLICY "Comments viewable by everyone" ON public.comments FOR SELECT USING (true);
CREATE POLICY "Comments insertable by everyone" ON public.comments FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Comments deletable by everyone" ON public.comments;
CREATE POLICY "Comments deletable by everyone" ON public.comments FOR DELETE USING (true);
DROP POLICY IF EXISTS "Comments updatable by everyone" ON public.comments;
CREATE POLICY "Comments updatable by everyone" ON public.comments FOR UPDATE USING (true);

-- Migration statements for existing databases:
ALTER TABLE public.comments ADD COLUMN IF NOT EXISTS "parentId" UUID REFERENCES public.comments(id) ON DELETE CASCADE;
ALTER TABLE public.comments ADD COLUMN IF NOT EXISTS "replyToUserName" TEXT;

-- Add cascade delete constraint on reports postId
ALTER TABLE public.reports DROP CONSTRAINT IF EXISTS fk_reports_post;
ALTER TABLE public.reports 
  ADD CONSTRAINT fk_reports_post 
  FOREIGN KEY ("postId") 
  REFERENCES public.posts(id) 
  ON DELETE CASCADE;

-- Delete policies
DROP POLICY IF EXISTS "Users can delete their own posts" ON public.posts;
CREATE POLICY "Users can delete their own posts" ON public.posts
  FOR DELETE USING (auth.uid() = "userId");

DROP POLICY IF EXISTS "Users can delete their own comments or comments on their posts" ON public.comments;
CREATE POLICY "Users can delete their own comments or comments on their posts" ON public.comments
  FOR DELETE USING (
    auth.uid() = "userId" OR 
    auth.uid() IN (SELECT "userId" FROM public.posts WHERE id = "postId")
  );

DROP POLICY IF EXISTS "Post owners can delete reports on their posts" ON public.reports;
CREATE POLICY "Post owners can delete reports on their posts" ON public.reports
  FOR DELETE USING (
    auth.uid() IN (SELECT "userId" FROM public.posts WHERE id = "postId")
  );


-- ========================================================
-- AUTO CLEAN UP DELETED USERS
-- ========================================================
-- Automatically delete the public.users record when the corresponding user is deleted from auth.users (Supabase Auth dashboard)
CREATE OR REPLACE FUNCTION public.handle_deleted_user()
RETURNS TRIGGER AS $$
BEGIN
  DELETE FROM public.users WHERE id = OLD.id;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER tr_handle_deleted_user
AFTER DELETE ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_deleted_user();


-- ========================================================
-- DEDUPLICATED CUSTOM STICKERS & REFERENCE COUNTING
-- ========================================================

-- Create stickers table for storing deduplicated custom stickers
CREATE TABLE IF NOT EXISTS public.stickers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sha256 TEXT UNIQUE NOT NULL,
  url TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for stickers
ALTER TABLE public.stickers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Stickers are viewable by everyone" ON public.stickers;
CREATE POLICY "Stickers are viewable by everyone" ON public.stickers FOR SELECT USING (true);
DROP POLICY IF EXISTS "Stickers can be inserted by everyone" ON public.stickers;
CREATE POLICY "Stickers can be inserted by everyone" ON public.stickers FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Stickers can be deleted by everyone" ON public.stickers;
CREATE POLICY "Stickers can be deleted by everyone" ON public.stickers FOR DELETE USING (true);

-- Create user_stickers junction table for reference counting
CREATE TABLE IF NOT EXISTS public.user_stickers (
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  "stickerId" UUID REFERENCES public.stickers(id) ON DELETE CASCADE NOT NULL,
  PRIMARY KEY ("userId", "stickerId")
);

-- Enable RLS for user_stickers
ALTER TABLE public.user_stickers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "User stickers are viewable by everyone" ON public.user_stickers;
CREATE POLICY "User stickers are viewable by everyone" ON public.user_stickers FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users can insert their own stickers" ON public.user_stickers;
CREATE POLICY "Users can insert their own stickers" ON public.user_stickers FOR INSERT WITH CHECK (auth.uid() = "userId");
DROP POLICY IF EXISTS "Users can delete their own stickers" ON public.user_stickers;
CREATE POLICY "Users can delete their own stickers" ON public.user_stickers FOR DELETE USING (auth.uid() = "userId");

-- ==========================================
-- EXPLORE FEED DISTRIBUTION & RECOMMENDATION
-- ==========================================

-- Enable the pgvector extension for AI similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Add distribution columns to posts table
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "embedding" vector(384);
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "tier" INTEGER DEFAULT 0; -- 0: Fresh/Evaluation, 1: Popular, 2: Viral
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "engagement_score" DOUBLE PRECISION DEFAULT 0.0;

-- Create post_metrics table to track raw signals
CREATE TABLE IF NOT EXISTS public.post_metrics (
  "postId" UUID REFERENCES public.posts(id) ON DELETE CASCADE,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE,
  "watched_duration" INTEGER DEFAULT 0, -- in seconds
  "completed" BOOLEAN DEFAULT FALSE,
  "skipped" BOOLEAN DEFAULT FALSE, -- scrolled away in <2 seconds
  "shared" BOOLEAN DEFAULT FALSE,
  "liked" BOOLEAN DEFAULT FALSE,
  "commented" BOOLEAN DEFAULT FALSE,
  "updated_at" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  PRIMARY KEY ("postId", "userId")
);

-- Enable RLS for post_metrics
ALTER TABLE public.post_metrics ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Metrics viewable by everyone" ON public.post_metrics;
CREATE POLICY "Metrics viewable by everyone" ON public.post_metrics FOR SELECT USING (true);
DROP POLICY IF EXISTS "Metrics insertable by everyone" ON public.post_metrics;
CREATE POLICY "Metrics insertable by everyone" ON public.post_metrics FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Metrics updatable by everyone" ON public.post_metrics;
CREATE POLICY "Metrics updatable by everyone" ON public.post_metrics FOR UPDATE USING (true);

-- Create user_interests table to store user embedding profiles
CREATE TABLE IF NOT EXISTS public.user_interests (
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE PRIMARY KEY,
  "interest_vector" vector(384) NOT NULL,
  "updated_at" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for user_interests
ALTER TABLE public.user_interests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Interests viewable by everyone" ON public.user_interests;
CREATE POLICY "Interests viewable by everyone" ON public.user_interests FOR SELECT USING (true);
DROP POLICY IF EXISTS "Interests insertable by everyone" ON public.user_interests;
CREATE POLICY "Interests insertable by everyone" ON public.user_interests FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Interests updatable by everyone" ON public.user_interests;
CREATE POLICY "Interests updatable by everyone" ON public.user_interests FOR UPDATE USING (true);

-- Create trigger function to update engagement scores
CREATE OR REPLACE FUNCTION public.update_post_engagement_score()
RETURNS TRIGGER AS $$
DECLARE
  v_completions INT;
  v_shares INT;
  v_comments INT;
  v_likes INT;
  v_skips INT;
  v_score DOUBLE PRECISION;
  v_post_id UUID;
BEGIN
  v_post_id := COALESCE(NEW."postId", OLD."postId");
  if v_post_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Count metrics for this postId
  SELECT 
    COUNT(CASE WHEN completed = TRUE THEN 1 END),
    COUNT(CASE WHEN shared = TRUE THEN 1 END),
    COUNT(CASE WHEN commented = TRUE THEN 1 END),
    COUNT(CASE WHEN liked = TRUE THEN 1 END),
    COUNT(CASE WHEN skipped = TRUE THEN 1 END)
  INTO 
    v_completions, v_shares, v_comments, v_likes, v_skips
  FROM public.post_metrics
  WHERE "postId" = v_post_id;

  -- Calculate weighted score
  v_score := (10 * v_completions) + (5 * v_shares) + (3 * v_comments) + (1 * v_likes) - (5 * v_skips);

  -- Update post score and escalate tier if necessary
  UPDATE public.posts
  SET 
    "engagement_score" = v_score,
    "tier" = CASE 
      WHEN v_score >= 100 THEN 2 -- Viral
      WHEN v_score >= 20 THEN 1  -- Popular
      ELSE 0                     -- Fresh
    END
  WHERE id = v_post_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Recreate trigger on post_metrics
DROP TRIGGER IF EXISTS trg_update_post_engagement ON public.post_metrics;
CREATE TRIGGER trg_update_post_engagement
AFTER INSERT OR UPDATE OR DELETE ON public.post_metrics
FOR EACH ROW
EXECUTE FUNCTION public.update_post_engagement_score();

-- RPC: Get Explore feed recommendations utilizing pgvector and tiered distribution
CREATE OR REPLACE FUNCTION public.get_explore_feed_recommendations(
  p_user_id UUID,
  p_limit INT DEFAULT 25
)
RETURNS SETOF public.posts AS $$
DECLARE
  v_user_vector vector(384);
BEGIN
  -- 1. Try to get user's interest vector
  SELECT interest_vector INTO v_user_vector
  FROM public.user_interests
  WHERE "userId" = p_user_id;

  -- 2. If user has no vector, fall back to default order by recency
  IF v_user_vector IS NULL THEN
    RETURN QUERY 
    SELECT * 
    FROM public.posts
    ORDER BY "createdAt" DESC
    LIMIT p_limit;
  ELSE
    -- 3. Mix: 80% interest-matched (popular/viral), 20% fresh/evaluation posts (Tier 0)
    RETURN QUERY
    (
      -- 80% Matched Tier 1 (Popular) or Tier 2 (Viral) posts, ordered by similarity
      SELECT *
      FROM public.posts
      WHERE "tier" > 0 AND "embedding" IS NOT NULL
      ORDER BY ("embedding" <=> v_user_vector) ASC
      LIMIT (p_limit * 80 / 100)
    )
    UNION ALL
    (
      -- 20% Fresh Tier 0 posts, ordered by recency to give them a chance
      SELECT *
      FROM public.posts
      WHERE "tier" = 0 OR "embedding" IS NULL
      ORDER BY "createdAt" DESC
      LIMIT (p_limit * 20 / 100)
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- RPC: Get Video feed recommendations utilizing pgvector and tiered distribution
CREATE OR REPLACE FUNCTION public.get_video_feed_recommendations(
  p_user_id UUID,
  p_limit INT DEFAULT 25
)
RETURNS SETOF public.posts AS $$
DECLARE
  v_user_vector vector(384);
BEGIN
  -- 1. Try to get user's interest vector
  SELECT interest_vector INTO v_user_vector
  FROM public.user_interests
  WHERE "userId" = p_user_id;

  -- 2. If user has no vector, fall back to default order by recency
  IF v_user_vector IS NULL THEN
    RETURN QUERY 
    SELECT * 
    FROM public.posts
    WHERE "mediaType" = 'video' OR "mediatype" = 'video'
    ORDER BY "createdAt" DESC
    LIMIT p_limit;
  ELSE
    -- 3. Mix: 80% interest-matched (popular/viral), 20% fresh/evaluation posts (Tier 0)
    RETURN QUERY
    (
      SELECT *
      FROM public.posts
      WHERE ("mediaType" = 'video' OR "mediatype" = 'video') AND "tier" > 0 AND "embedding" IS NOT NULL
      ORDER BY ("embedding" <=> v_user_vector) ASC
      LIMIT (p_limit * 80 / 100)
    )
    UNION ALL
    (
      SELECT *
      FROM public.posts
      WHERE ("mediaType" = 'video' OR "mediatype" = 'video') AND ("tier" = 0 OR "embedding" IS NULL)
      ORDER BY "createdAt" DESC
      LIMIT (p_limit * 20 / 100)
    );
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ========================================================
-- ADMIN PORTAL SYSTEM CONFIGURATIONS
-- ========================================================

-- Add role column to public.users table if it does not exist (defaults to 'user')
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'user' NOT NULL;

-- Create admin_audit_logs table to track administrative actions
CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "adminId" UUID REFERENCES public.users(id) ON DELETE SET NULL,
  "adminName" TEXT NOT NULL,
  action TEXT NOT NULL,
  details TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for admin_audit_logs
ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin logs viewable by admins only" ON public.admin_audit_logs;
CREATE POLICY "Admin logs viewable by admins only" ON public.admin_audit_logs
  FOR SELECT USING (
    auth.uid() IN (SELECT id FROM public.users WHERE role = 'admin' OR role = 'super_admin')
  );
DROP POLICY IF EXISTS "Admins can insert audit logs" ON public.admin_audit_logs;
CREATE POLICY "Admins can insert audit logs" ON public.admin_audit_logs
  FOR INSERT WITH CHECK (true);

-- Create app_settings table to store global configuration settings
CREATE TABLE IF NOT EXISTS public.app_settings (
  key TEXT PRIMARY KEY,
  value BOOLEAN NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for app_settings
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "App settings viewable by everyone" ON public.app_settings;
CREATE POLICY "App settings viewable by everyone" ON public.app_settings
  FOR SELECT USING (true);
DROP POLICY IF EXISTS "App settings modifiable by admins only" ON public.app_settings;
CREATE POLICY "App settings modifiable by admins only" ON public.app_settings
  FOR ALL USING (
    auth.uid() IN (SELECT id FROM public.users WHERE role = 'admin' OR role = 'super_admin')
  );

-- Migration statements for comment likes and pinned status:
ALTER TABLE public.comments ADD COLUMN IF NOT EXISTS "likes" INT DEFAULT 0;
ALTER TABLE public.comments ADD COLUMN IF NOT EXISTS "isPinned" BOOLEAN DEFAULT false;

-- Migration statements for short-video posts support:
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "videoUrl" TEXT;
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "mediaType" TEXT DEFAULT 'text';
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS "saves" INTEGER DEFAULT 0 NOT NULL;
ALTER TABLE public.post_metrics ADD COLUMN IF NOT EXISTS "saved" BOOLEAN DEFAULT FALSE NOT NULL;

-- ========================================================
-- SELF-HOSTED GATEWAY SERVICES AUTH AND CACHING TABLES
-- ========================================================

-- Store credentials for Go-auth users
CREATE TABLE IF NOT EXISTS public.auth_credentials (
  id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  salt VARCHAR(255) NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Store Go-auth user refresh tokens
CREATE TABLE IF NOT EXISTS public.refresh_tokens (
  token VARCHAR(255) PRIMARY KEY,
  user_id UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  expires_at BIGINT NOT NULL,
  revoked BOOLEAN DEFAULT false NOT NULL,
  parent_token VARCHAR(255)
);

-- Store muted chats per user
CREATE TABLE IF NOT EXISTS public.muted_chats (
  user_id VARCHAR(255) PRIMARY KEY,
  muted_chats TEXT[] NOT NULL DEFAULT '{}'::TEXT[]
);

-- Store verification codes for email signups
CREATE TABLE IF NOT EXISTS public.verification_codes (
  email VARCHAR(255) PRIMARY KEY,
  code VARCHAR(10) NOT NULL,
  expires_at BIGINT NOT NULL
);

-- Store temporary/undelivered chat messages (replacing DynamoDB ReelMessages)
CREATE TABLE IF NOT EXISTS public.chat_messages (
  chat_id VARCHAR(255) NOT NULL,
  message_id VARCHAR(255) NOT NULL,
  sender_id VARCHAR(255) NOT NULL,
  recipient_id VARCHAR(255) NOT NULL,
  text TEXT,
  media_url TEXT,
  media_type VARCHAR(50),
  timestamp BIGINT NOT NULL,
  status VARCHAR(50) DEFAULT 'sent',
  expires_at BIGINT NOT NULL,
  PRIMARY KEY (chat_id, message_id)
);


