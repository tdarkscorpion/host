import os
import time
import subprocess
import pymysql

# Database connection details (can be overridden by environment variables)
DB_HOST = os.getenv("DB_HOST", "127.0.0.1")
DB_USER = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "talisman_pwd")
DB_NAME = os.getenv("DB_NAME", "db_account")
DB_PORT = int(os.getenv("DB_PORT", "3309")) # Docker MySQL port. Change to 3306 if using native host MySQL.

IPSET_NAME = "game_whitelist"
SYNC_INTERVAL = 3.0 # seconds

def run_cmd(cmd):
    try:
        subprocess.run(cmd, shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        pass # Ignore errors (e.g. if IP already exists in ipset)

def init_ipset():
    # Ensure ipset exists. Timeout 86400 = 24 hours expiration.
    run_cmd(f"ipset create {IPSET_NAME} hash:ip timeout 86400 -exist")

def main():
    init_ipset()
    
    # Store the last processed ID so we only query new IPs
    last_id = 0
    last_cleanup_time = time.time()
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Firewall sync daemon started.")
    
    while True:
        try:
            conn = pymysql.connect(
                host=DB_HOST,
                user=DB_USER,
                password=DB_PASSWORD,
                database=DB_NAME,
                port=DB_PORT,
                cursorclass=pymysql.cursors.DictCursor
            )
            
            with conn.cursor() as cursor:
                if last_id == 0:
                    cursor.execute("SELECT MAX(id) as max_id FROM db_valid_ip")
                    result = cursor.fetchone()
                    if result and result['max_id']:
                        last_id = result['max_id']
                    
                    # On first run, we process all currently valid IPs
                    cursor.execute("SELECT id, wan_ip FROM db_valid_ip ORDER BY id ASC")
                else:
                    cursor.execute("SELECT id, wan_ip FROM db_valid_ip WHERE id > %s ORDER BY id ASC", (last_id,))
                
                rows = cursor.fetchall()
                for row in rows:
                    ip = row['wan_ip']
                    if row['id'] > last_id:
                        last_id = row['id']
                    
                    # Add to ipset (resets timeout if already exists)
                    run_cmd(f"ipset add {IPSET_NAME} {ip} -exist")
                    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Whitelisted IP: {ip}")
            
            conn.close()
            
            # Auto-cleanup database every hour to prevent bloat
            current_time = time.time()
            if current_time - last_cleanup_time > 3600:
                try:
                    conn = pymysql.connect(
                        host=DB_HOST, user=DB_USER, password=DB_PASSWORD,
                        database=DB_NAME, port=DB_PORT
                    )
                    with conn.cursor() as cursor:
                        # Delete records older than 24 hours
                        cursor.execute("DELETE FROM db_valid_ip WHERE timestamp < NOW() - INTERVAL 1 DAY")
                    conn.commit()
                    conn.close()
                    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Performed automated database cleanup.")
                    last_cleanup_time = current_time
                except Exception as e:
                    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Cleanup error: {e}")
                    
        except Exception as e:
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Database connection error: {e}")
        
        time.sleep(SYNC_INTERVAL)

if __name__ == "__main__":
    main()
