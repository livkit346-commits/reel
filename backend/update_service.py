import paramiko
import sys

def main():
    host = "54.205.149.147"
    username = "ubuntu"
    key_path = "reel-key.pem"
    
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    db_url = "postgres://postgres.zvxrcwgvvubgqlxbcyov:blackfist13133@aws-0-eu-west-1.pooler.supabase.com:5432/postgres"
    
    try:
        print(f"Connecting to EC2 server ({host})...")
        key = paramiko.RSAKey.from_private_key_file(key_path)
        ssh.connect(hostname=host, username=username, pkey=key, timeout=15)
        
        # 1. Read existing reel.service
        print("Reading reel.service file...")
        stdin, stdout, stderr = ssh.exec_command("cat /etc/systemd/system/reel.service")
        service_content = stdout.read().decode('utf-8')
        
        # 2. Modify content to insert DATABASE_URL
        lines = service_content.splitlines()
        updated_lines = []
        has_db_url = False
        
        for line in lines:
            if "Environment=DATABASE_URL=" in line:
                updated_lines.append(f"Environment=DATABASE_URL={db_url}")
                has_db_url = True
            else:
                updated_lines.append(line)
        
        # If not present, insert it after PORT environment variable
        if not has_db_url:
            new_lines = []
            for line in updated_lines:
                new_lines.append(line)
                if "Environment=PORT=" in line:
                    new_lines.append(f"Environment=DATABASE_URL={db_url}")
            updated_lines = new_lines
            
        final_content = "\n".join(updated_lines) + "\n"
        
        # 3. Write temp service file on remote
        print("Uploading updated service file...")
        sftp = ssh.open_sftp()
        temp_remote_path = "/home/ubuntu/reel.service"
        with sftp.file(temp_remote_path, 'w') as f:
            f.write(final_content)
        sftp.close()
        
        # 4. Copy to systemd and reload
        commands = [
            "sudo cp /home/ubuntu/reel.service /etc/systemd/system/reel.service",
            "rm -f /home/ubuntu/reel.service",
            "sudo systemctl daemon-reload",
            "sudo systemctl restart reel",
            "sleep 2",
            "sudo systemctl status reel"
        ]
        
        print("Applying changes and restarting systemd service...")
        for cmd in commands:
            print(f"Running: {cmd}")
            stdin, stdout, stderr = ssh.exec_command(cmd)
            exit_status = stdout.channel.recv_exit_status()
            out = stdout.read().decode('utf-8', errors='replace')
            err = stderr.read().decode('utf-8', errors='replace')
            if out:
                sys.stdout.buffer.write(f"STDOUT:\n{out}".encode('utf-8'))
                print()
            if err:
                sys.stdout.buffer.write(f"STDERR:\n{err}".encode('utf-8'))
                print()
            if exit_status != 0 and "rm" not in cmd:
                print(f"Command failed with exit status {exit_status}")
                
        print("Server configuration updated successfully!")
        
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
    finally:
        ssh.close()

if __name__ == "__main__":
    main()
