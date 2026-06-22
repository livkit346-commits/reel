import os
import gzip
import shutil
import subprocess
import sys

def main():
    local_file = r"c:\Users\Hp\.gemini\antigravity\scratch\reel\backend\reel-backend"
    local_gz = local_file + ".gz"
    
    # 1. Gzip the binary locally
    print("Compressing binary locally...")
    with open(local_file, 'rb') as f_in:
        with gzip.open(local_gz, 'wb') as f_out:
            shutil.copyfileobj(f_in, f_out)
    print("Local compression complete.")
    
    # 2. Upload via scp
    print("Uploading file to EC2 using scp with bandwidth limit...")
    scp_cmd = [
        "scp",
        "-i", "reel-key.pem",
        "-o", "StrictHostKeyChecking=no",
        local_gz,
        "ubuntu@54.205.149.147:/home/ubuntu/reel-backend.gz"
    ]
    res = subprocess.run(scp_cmd)
    if res.returncode != 0:
        print("SCP upload failed.")
        sys.exit(1)
        
    print("SCP upload complete.")
    
    # 3. Stop service, gunzip, and restart service via ssh
    print("Running remote commands via ssh...")
    ssh_cmd = [
        "ssh",
        "-i", "reel-key.pem",
        "-o", "StrictHostKeyChecking=no",
        "ubuntu@54.205.149.147",
        "sudo systemctl stop reel && "
        "gunzip -f /home/ubuntu/reel-backend.gz && "
        "chmod +x /home/ubuntu/reel-backend && "
        "sudo systemctl daemon-reload && "
        "sudo systemctl start reel && "
        "sleep 2 && "
        "sudo systemctl status reel"
    ]
    res = subprocess.run(ssh_cmd)
    if res.returncode != 0:
        print("SSH remote execution failed.")
        sys.exit(1)
        
    print("Deployment completed successfully!")
    
    # Clean up local gz
    if os.path.exists(local_gz):
        os.remove(local_gz)

if __name__ == "__main__":
    main()
