# Reel Messaging Gateway Backend (Go)

This is a high-performance, low-cost WebSocket gateway server for the Reel app. It handles real-time user connections, validates sessions via Firebase Auth, stores messages in AWS DynamoDB, and sends push notifications via Firebase Cloud Messaging (FCM) to offline users.

---

## 🛠️ Step 1: Create the AWS DynamoDB Table
Before running the backend, create the DynamoDB table:

1. Open your **AWS Console** -> Go to **DynamoDB**.
2. Click **Create table**.
3. Set the configurations:
   - **Table name**: `ReelMessages`
   - **Partition key (PK)**: `chatId` (Type: `String`)
   - **Sort key (SK)**: `messageId` (Type: `String`)
4. Leave all other settings as default and click **Create table**.

---

## 🔑 Step 2: Download Firebase Service Account Key
To authenticate user tokens and send push notifications, the backend needs access to the Firebase Admin SDK:

1. Go to your **Firebase Console** -> Click the Gear Icon ⚙️ -> **Project Settings**.
2. Go to the **Service Accounts** tab.
3. Click **Generate new private key** (at the bottom).
4. Save the downloaded JSON file, rename it to exactly **`firebase-service-account.json`**, and drop it inside this `backend/` folder.

---

## 💻 Step 3: Run the Server Locally

### 1. Set environment variables
Set your Supabase and AWS credentials in your terminal session.

**On Windows (Command Prompt)**:
```cmd
set SUPABASE_URL=https://your-project.supabase.co
set SUPABASE_ANON_KEY=your-supabase-anon-key
set AWS_ACCESS_KEY_ID=your-aws-access-key-id
set AWS_SECRET_ACCESS_KEY=your-aws-secret-access-key
set AWS_REGION=us-east-1
```

**On Mac/Linux**:
```bash
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_ANON_KEY="your-supabase-anon-key"
export AWS_ACCESS_KEY_ID="your-aws-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-aws-secret-access-key"
export AWS_REGION="us-east-1"
```

### 2. Run the Go server
Make sure you have Go installed (`golang.org`), navigate to the `backend/` directory, and run:
```bash
go run main.go
```
The server will start listening on port `8080` (e.g. `ws://localhost:8080/ws`).
