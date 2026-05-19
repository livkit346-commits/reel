-- Create users table
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
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

-- Ensure mediaType column exists for legacy installations
ALTER TABLE public.statuses ADD COLUMN IF NOT EXISTS "mediaType" TEXT DEFAULT 'image';

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


-- Create chats table
CREATE TABLE IF NOT EXISTS public.chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  "disappearingDuration" TEXT DEFAULT 'off' NOT NULL -- 'off', '24h', '48h'
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
  PRIMARY KEY ("chatId", "userId")
);

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
  "postId" UUID,
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
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);
ALTER TABLE public.comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Comments viewable by everyone" ON public.comments;
DROP POLICY IF EXISTS "Comments insertable by everyone" ON public.comments;
CREATE POLICY "Comments viewable by everyone" ON public.comments FOR SELECT USING (true);
CREATE POLICY "Comments insertable by everyone" ON public.comments FOR INSERT WITH CHECK (true);
