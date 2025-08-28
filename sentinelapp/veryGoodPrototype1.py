# ================================
# Pico W – Home Security + Bluetooth (Optimized)
# Keypad responsive + Core1 only for Bluetooth
# ================================

import time, _thread
from machine import Pin, PWM, I2C, ADC, UART, time_pulse_us
import dht, ssd1306, urequests, network

# ---------------- Config ----------------
SSID = "Batman"
PASSWORD_WIFI = "iambatman"
PASSWORD_CODE = ['1','1','1','1']
ULTRA_THRESHOLD_CM = 10.0
TEMP_THRESHOLD = 40
HUM_THRESHOLD = 120
GAS_THRESHOLD = 10000
DOOR_OPEN_ANGLE = 90
DOOR_CLOSED_ANGLE = 0
SENSOR_SCAN_INTERVAL = 0.05
DHT_UPDATE_MS = 3000
FIREBASE_UPDATE_MS = 2000
OLED_UPDATE_MS = 200
FIREBASE_URL = "https://cse331-a7e3b-default-rtdb.firebaseio.com/sensor.json"

# ---------------- Wi-Fi ----------------
def wifi_connect(ssid=SSID, password=PASSWORD_WIFI):
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)
    if not wlan.isconnected():
        print("Connecting to Wi-Fi...")
        wlan.connect(ssid, password)
        while not wlan.isconnected():
            time.sleep_ms(200)
    print("Wi-Fi connected:", wlan.ifconfig())

wifi_connect()

# ---------------- Peripherals ----------------
i2c = I2C(0, scl=Pin(5), sda=Pin(4))
oled = ssd1306.SSD1306_I2C(128, 64, i2c)
dht_sensor = dht.DHT11(Pin(2))
trig = Pin(14, Pin.OUT)
echo = Pin(15, Pin.IN)
ir = Pin(16, Pin.IN)
mq2 = ADC(Pin(26))
buzzer = Pin(13, Pin.OUT)

servo = PWM(Pin(10))
servo.freq(50)
servo_target = DOOR_CLOSED_ANGLE
servo_current = DOOR_CLOSED_ANGLE
servo_last_update = 0

def set_servo_angle(angle):
    pulse_ms = 0.5 + (angle/180.0)*2.0
    duty = int((pulse_ms/20)*65535)
    servo.duty_u16(duty)

# Keypad
rows = [Pin(6,Pin.OUT),Pin(7,Pin.OUT),Pin(8,Pin.OUT),Pin(9,Pin.OUT)]
cols = [Pin(28,Pin.IN,Pin.PULL_DOWN),Pin(27,Pin.IN,Pin.PULL_DOWN),
        Pin(26,Pin.IN,Pin.PULL_DOWN),Pin(22,Pin.IN,Pin.PULL_DOWN)]
KEYS = [["D","C","B","A"],["#","9","6","3"],["0","8","5","2"],["*","7","4","1"]]

# Bluetooth UART + LED
bt = UART(0, 9600)
led = Pin(12, Pin.OUT)

# ---------------- Shared State ----------------
state = {
    'distance_cm': None, 'ir_detect': False,
    'gas_detect': False, 'gas_value': 0,
    'temp_c': None, 'hum_pct': None,
    'door_open': False, 'alarm': False,
    'wrong_attempts': 0, 'status': 'READY',
    'input_code': [], 'last_dht_update': 0,
    'last_fb_update': 0, 'send_fb': False,
    'oled_last_update': 0,
    'password_alarm': False
}

# ---------------- Helpers ----------------
def get_distance_cm():
    trig.low(); time.sleep_us(2)
    trig.high(); time.sleep_us(10); trig.low()
    dur = time_pulse_us(echo, 1, 15000)
    if dur < 0: return None
    return (dur/2)/29.1

def read_dht_safe():
    try:
        dht_sensor.measure()
        return dht_sensor.temperature(), dht_sensor.humidity()
    except:
        return None, None

def scan_keypad_once():
    for r in rows: r.low()
    for ri, r in enumerate(rows):
        r.high()
        for ci, c in enumerate(cols):
            if c.value() == 1:
                while c.value() == 1: time.sleep_ms(5)
                r.low()
                return KEYS[ri][ci]
        r.low()
    return None

def send_to_firebase():
    try:
        now = time.localtime()
        timestamp = "{:04d}-{:02d}-{:02d} {:02d}:{:02d}:{:02d}".format(
            now[0], now[1], now[2], now[3], now[4], now[5]
        )
        data = {
            'distance_cm': state['distance_cm'],
            'ir_detect': state['ir_detect'],
            'gas_detect': state['gas_detect'],
            'gas_value': state['gas_value'],
            'temp_c': state['temp_c'],
            'hum_pct': state['hum_pct'],
            'door_open': state['door_open'],
            'alarm': state['alarm'] or state['password_alarm'],
            'wrong_attempts': state['wrong_attempts'],
            'status': state['status'],
            'timestamp': timestamp
        }
        urequests.patch(FIREBASE_URL, json=data).close()
    except Exception as e:
        print("Firebase error:", e)

# ---------------- Core1 Thread (Bluetooth only) ----------------
def core1_task():
    print("HC-05 Bluetooth Ready!")
    while True:
        if state['send_fb']:
            send_to_firebase()
            state['send_fb'] = False

        if bt.any():
            data = bt.readline()
            if data:
                cmd = data.decode('utf-8').strip().lower()
                if cmd == "turn on led": led.value(1); bt.write("LED ON\n")
                elif cmd == "turn off led": led.value(0); bt.write("LED OFF\n")
                elif cmd == "open door": global servo_target; servo_target = DOOR_OPEN_ANGLE; bt.write("Door OPENED\n")
                elif cmd == "close door": servo_target = DOOR_CLOSED_ANGLE; bt.write("Door CLOSED\n")
                elif cmd == "alarm on": state['alarm']=True; bt.write("Alarm ON\n")
                elif cmd == "alarm off": state['alarm']=False; bt.write("Alarm OFF\n")
                else: bt.write("Unknown command\n")
        time.sleep_ms(50)

_thread.start_new_thread(core1_task, ())

# ---------------- Main Loop (Core0) ----------------
while True:
    now = time.ticks_ms()

    # --- Sensor reading ---
    dist = get_distance_cm()
    ir_det = (ir.value() == 0)
    gas_val = mq2.read_u16()
    gas_det = gas_val > GAS_THRESHOLD

    if time.ticks_diff(now, state['last_dht_update']) >= DHT_UPDATE_MS:
        t, h = read_dht_safe()
        if t is not None: state['temp_c'] = t
        if h is not None: state['hum_pct'] = h
        state['last_dht_update'] = now

    state['distance_cm'] = round(dist,1) if dist else None
    state['ir_detect'] = ir_det
    state['gas_value'] = gas_val
    state['gas_detect'] = gas_det

    # --- Alarm logic ---
    sensor_alarm = ((dist is not None and dist < ULTRA_THRESHOLD_CM) or ir_det)
    sensor_alarm = sensor_alarm or gas_det or \
                   (state['temp_c'] is not None and state['temp_c'] > TEMP_THRESHOLD) or \
                   (state['hum_pct'] is not None and state['hum_pct'] > HUM_THRESHOLD)
    state['alarm'] = sensor_alarm or state['password_alarm']
    buzzer.value(state['alarm'])

    # --- Keypad handling (fast, non-blocking) ---
    key = scan_keypad_once()
    if key:
        buzzer.on(); time.sleep_ms(50); buzzer.off()
        code_len = len(state['input_code'])
        if key == 'D':
            if code_len>0:
                if state['input_code'] == PASSWORD_CODE:
                    state['status']='ACCESS GRANTED'; state['wrong_attempts']=0
                    state['password_alarm'] = False
                    servo_target = DOOR_OPEN_ANGLE
                else:
                    state['status']='ACCESS DENIED'; state['wrong_attempts']+=1
                    if state['wrong_attempts']>=3:
                        state['password_alarm'] = True
                        state['status']='ALARM TRIGGERED!'
                    else:
                        state['password_alarm'] = False
                state['input_code']=[] 
        elif key=='C': state['alarm']=False; state['password_alarm']=False; state['wrong_attempts']=0; state['status']='ALARM OFF'; state['input_code']=[] 
        elif key=='B': servo_target=DOOR_CLOSED_ANGLE; state['door_open']=False; state['status']='LOCKED'; state['input_code']=[] 
        elif key=='A': servo_target=DOOR_OPEN_ANGLE; state['door_open']=True; state['status']='UNLOCKED'; state['input_code']=[] 
        elif key in '0123456789' and code_len<4: state['input_code'].append(key)

    # --- Servo non-blocking ---
    if time.ticks_diff(now, servo_last_update) >= 20:
        if servo_current < servo_target: servo_current+=3
        elif servo_current > servo_target: servo_current-=3
        set_servo_angle(servo_current)
        servo_last_update = now
        state['door_open'] = servo_current>=DOOR_OPEN_ANGLE

    # --- Firebase flag ---
    if time.ticks_diff(now, state['last_fb_update']) >= FIREBASE_UPDATE_MS:
        state['last_fb_update'] = now
        state['send_fb'] = True

    # --- OLED ---
    if time.ticks_diff(now, state['oled_last_update']) >= OLED_UPDATE_MS:
        oled.fill(0)
        oled.text("SENTINEL:ARMED",0,0)
        oled.text("D:{} I:{} G:{}".format(
            '---' if state['distance_cm'] is None else state['distance_cm'],
            'N' if not state['ir_detect'] else 'Y',
            'Y' if state['gas_detect'] else 'N'),0,10)
        oled.text("T:{}C H:{}%".format(
            '--' if state['temp_c'] is None else state['temp_c'],
            '--' if state['hum_pct'] is None else state['hum_pct']),0,20)
        oled.text("DOOR:{} ALR:{}".format(
            "OP" if state['door_open'] else "CL",
            "ON" if state['alarm'] else "OFF"),0,30)
        oled.text("PASS:{}".format(''.join(state['input_code'])),0,40)
        oled.text("TRIES:{}".format(state['wrong_attempts']),0,50)
        oled.show()
        state['oled_last_update'] = now

    time.sleep_ms(int(SENSOR_SCAN_INTERVAL*1000))
