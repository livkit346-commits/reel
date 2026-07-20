import boto3
import psycopg2
import sys
import os

def main():
    # 1. AWS Credentials
    aws_access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    aws_secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    region_name = os.environ.get("AWS_REGION", "us-east-1")
    
    # 2. PostgreSQL Connection details
    db_url = os.environ.get("DATABASE_URL")
    
    if not aws_access_key or not aws_secret_key or not db_url:
        print("Error: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and DATABASE_URL environment variables must be set.")
        sys.exit(1)
        
    try:
        # 3. Connect to DynamoDB
        print("Connecting to AWS DynamoDB...")
        dynamodb = boto3.resource(
            'dynamodb',
            aws_access_key_id=aws_access_key,
            aws_secret_access_key=aws_secret_key,
            region_name=region_name
        )
        table = dynamodb.Table('ReelUsers')
        
        # Scan all users
        print("Scanning user accounts from ReelUsers DynamoDB table...")
        response = table.scan()
        items = response.get('Items', [])
        
        # Follow pagination if table is large
        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            items.extend(response.get('Items', []))
            
        print(f"Retrieved {len(items)} user records from DynamoDB.")
        if len(items) == 0:
            print("No users found to migrate.")
            return
            
        # 4. Connect to Supabase PostgreSQL
        print("Connecting to Supabase PostgreSQL...")
        conn = psycopg2.connect(db_url)
        cursor = conn.cursor()
        
        # 5. Insert users into public.users and public.auth_credentials
        migrated_count = 0
        for item in items:
            user_id = item.get('userId')
            email = item.get('email', '').strip().lower()
            password_hash = item.get('passwordHash')
            salt = item.get('salt')
            name = item.get('name', 'User')
            photo_url = item.get('photoUrl', '')
            
            if not user_id or not email or not password_hash or not salt:
                print(f"Skipping incomplete record: {email}")
                continue
                
            try:
                # Insert into public.users first (required for foreign key references)
                # Since supabase auth sync might have created some rows in users, we use ON CONFLICT DO NOTHING or UPDATE
                cursor.execute(
                    """
                    INSERT INTO public.users (id, name, "photoUrl")
                    VALUES (%s, %s, %s)
                    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, "photoUrl" = EXCLUDED."photoUrl"
                    """,
                    (user_id, name, photo_url)
                )
                
                # Insert credentials
                cursor.execute(
                    """
                    INSERT INTO public.auth_credentials (id, email, password_hash, salt)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, password_hash = EXCLUDED.password_hash, salt = EXCLUDED.salt
                    """,
                    (user_id, email, password_hash, salt)
                )
                migrated_count += 1
                print(f"Migrated: {email} ({name})")
            except Exception as row_err:
                print(f"Failed to migrate row for {email}: {row_err}")
                conn.rollback()
                
        conn.commit()
        cursor.close()
        conn.close()
        
        print(f"Successfully migrated {migrated_count} user accounts to PostgreSQL!")
        
    except Exception as e:
        print(f"Migration failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
