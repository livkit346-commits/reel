import sys
import paramiko
import os
import gzip
import shutil

def main():
    host = "54.205.149.147"
    username = "ubuntu"
    key_path = r"c:\Users\Hp\.gemini\antigravity\scratch\reel\backend\reel-key.pem"
    local_file = r"c:\Users\Hp\.gemini\antigravity\scratch\reel\backend\reel-backend"
    local_gz = local_file + ".gz"
    remote_gz = "/home/ubuntu/reel-backend.gz"
    remote_file = "/home/ubuntu/reel-backend"
    
    # 1. Compress the file locally
    print(f"Compressing {local_file} -> {local_gz}...")
    try:
        with open(local_file, 'rb') as f_in:
            with gzip.open(local_gz, 'wb') as f_out:
                shutil.copyfileobj(f_in, f_out)
        orig_size = os.path.getsize(local_file)
        gz_size = os.path.getsize(local_gz)
        print(f"Compressed: {orig_size} bytes -> {gz_size} bytes ({(gz_size/orig_size)*100:.1f}%)")
    except Exception as e:
        print(f"Failed to compress file: {e}")
        sys.exit(1)
        
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        print(f"Connecting to {host}...")
        key = paramiko.RSAKey.from_private_key_file(key_path)
        ssh.connect(hostname=host, username=username, pkey=key, timeout=15)
        
        # 2. Start SFTP client and upload file first
        print(f"Uploading {local_gz} to {remote_gz}...")
        sftp = ssh.open_sftp()
        
        def progress(transferred, total):
            pct = (transferred / total) * 100
            sys.stdout.write(f"\rUploading: {pct:.1f}% ({transferred}/{total} bytes)")
            sys.stdout.flush()
            
        sftp.put(local_gz, remote_gz, callback=progress)
        print("\nUpload complete.")
        sftp.close()
        
        # 3. Stop service, gunzip, and restart service
        print("Stopping service and updating binary...")
        commands = [
            "sudo systemctl stop reel",
            f"gunzip -f {remote_gz}",
            f"chmod +x {remote_file}",
            "sudo systemctl daemon-reload",
            "sudo systemctl start reel",
            "sleep 2",
            "sudo systemctl status reel"
        ]
        
        for cmd in commands:
            print(f"Running: {cmd}")
            stdin, stdout, stderr = ssh.exec_command(cmd)
            # Wait for command to finish
            exit_status = stdout.channel.recv_exit_status()
            out = stdout.read().decode('utf-8', errors='replace')
            err = stderr.read().decode('utf-8', errors='replace')
            if out:
                print(f"STDOUT:\n{out}")
            if err:
                print(f"STDERR:\n{err}")
            if exit_status != 0 and cmd != "sudo systemctl stop reel": # stop reel might return non-zero if already stopped
                print(f"Command failed with exit status {exit_status}")
                
        # Clean up local temp gzip file
        if os.path.exists(local_gz):
            os.remove(local_gz)
            
    except Exception as e:
        print(f"\nError: {e}")
        if os.path.exists(local_gz):
            os.remove(local_gz)
        sys.exit(1)
    finally:
        ssh.close()

if __name__ == "__main__":
    main()
