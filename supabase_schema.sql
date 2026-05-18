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

-- Enable Row Level Security (RLS) for users
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

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
  userId UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  userName TEXT NOT NULL,
  text TEXT NOT NULL,
  imageUrl TEXT,
  createdAt TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  likes INTEGER DEFAULT 0 NOT NULL
);

-- Enable RLS for posts
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;

-- Allow anyone to read posts (for the feed)
CREATE POLICY "Posts are viewable by everyone" ON public.posts
  FOR SELECT USING (true);

-- Allow authenticated users to create posts
CREATE POLICY "Users can create posts" ON public.posts
  FOR INSERT WITH CHECK (auth.uid() = "userId");


-- Create statuses table
CREATE TABLE IF NOT EXISTS public.statuses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  userId UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  userName TEXT NOT NULL,
  imageUrl TEXT NOT NULL,
  createdAt TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS for statuses
ALTER TABLE public.statuses ENABLE ROW LEVEL SECURITY;

-- Allow anyone to read statuses
CREATE POLICY "Statuses are viewable by everyone" ON public.statuses
  FOR SELECT USING (true);

-- Allow authenticated users to create statuses
CREATE POLICY "Users can create statuses" ON public.statuses
  FOR INSERT WITH CHECK (auth.uid() = "userId");


-- Create chats table
CREATE TABLE IF NOT EXISTS public.chats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "createdAt" TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  "disappearingDuration" TEXT DEFAULT 'off' NOT NULL -- 'off', '24h', '48h'
);

-- Enable RLS for chats
ALTER TABLE public.chats ENABLE ROW LEVEL SECURITY;
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
CREATE POLICY "Messages viewable by everyone" ON public.messages FOR SELECT USING (true);
CREATE POLICY "Messages insertable by everyone" ON public.messages FOR INSERT WITH CHECK (true);
CREATE POLICY "Messages updatable by everyone" ON public.messages FOR UPDATE USING (true);
CREATE POLICY "Messages deletable by everyone" ON public.messages FOR DELETE USING (true);


-- Enable Realtime for messages table
alter publication supabase_realtime add table public.messages;


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
CREATE POLICY "Channels are viewable by everyone" ON public.channels FOR SELECT USING (true);
CREATE POLICY "Channels can be inserted by creator" ON public.channels FOR INSERT WITH CHECK (true);


-- Create channel_subscribers table
CREATE TABLE IF NOT EXISTS public.channel_subscribers (
  "channelId" UUID REFERENCES public.channels(id) ON DELETE CASCADE NOT NULL,
  "userId" UUID REFERENCES public.users(id) ON DELETE CASCADE NOT NULL,
  PRIMARY KEY ("channelId", "userId")
);

ALTER TABLE public.channel_subscribers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Subscribers are viewable by everyone" ON public.channel_subscribers FOR SELECT USING (true);
CREATE POLICY "Subscribers can be inserted by user" ON public.channel_subscribers FOR INSERT WITH CHECK (true);
CREATE POLICY "Subscribers can be deleted by user" ON public.channel_subscribers FOR DELETE USING (true);



