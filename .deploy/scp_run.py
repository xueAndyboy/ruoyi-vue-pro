import os
import pty
import select
import sys

def run_scp(local_path, remote_path):
    password = "xgs123456789.\n"
    scp_args = [
        "scp",
        "-P", "2222",
        "-o", "StrictHostKeyChecking=no",
        "-r",
        local_path,
        f"yeeco@192.168.100.201:{remote_path}"
    ]
    
    pid, fd = pty.fork()
    if pid == 0:
        # Child process
        os.execvp("scp", scp_args)
    else:
        # Parent process
        password_sent = False
        output = b""
        
        while True:
            r, w, e = select.select([fd], [], [], 600)
            if not r:
                print("\n[SCP Script Timeout after 600s]")
                break
            try:
                data = os.read(fd, 1024)
            except OSError:
                break
            if not data:
                break
                
            output += data
            # Print to stdout in real-time
            sys.stdout.buffer.write(data)
            sys.stdout.flush()
            
            # Detect password prompt
            if b"password:" in data.lower() and not password_sent:
                os.write(fd, password.encode())
                password_sent = True
                
        # Wait for child process to exit
        _, status = os.waitpid(pid, 0)
        return status

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 scp_run.py <local_path> <remote_path>")
        sys.exit(1)
    
    local = sys.argv[1]
    remote = sys.argv[2]
    run_scp(local, remote)
