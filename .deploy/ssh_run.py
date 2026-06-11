import os
import pty
import select
import sys

def run_ssh_command(cmd_str):
    password = "xgs123456789.\n"
    ssh_args = [
        "ssh", 
        "-p", "2222", 
        "-o", "StrictHostKeyChecking=no", 
        "-o", "PreferredAuthentications=password", 
        "yeeco@192.168.100.201", 
        cmd_str
    ]
    
    pid, fd = pty.fork()
    if pid == 0:
        # Child process
        os.execvp("ssh", ssh_args)
    else:
        # Parent process
        password_sent = False
        output = b""
        
        while True:
            r, w, e = select.select([fd], [], [], 600)
            if not r:
                print("\n[SSH Script Timeout after 600s]")
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
    if len(sys.argv) < 2:
        print("Usage: python3 ssh_run.py <command>")
        sys.exit(1)
    
    cmd = sys.argv[1]
    run_ssh_command(cmd)
