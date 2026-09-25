import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ConnState, RemoteCmd, ServerMessage } from '../model/RemoteProtocol';

const DOMAIN: number = 0x0000;
const TAG: string = 'WinRemote';

export class RemoteClient {
  onState: (state: ConnState, detail: string) => void = (state: ConnState, detail: string) => {
  };

  onMessage: (msg: ServerMessage) => void = (msg: ServerMessage) => {
  };

  onFrame: (data: ArrayBuffer) => void = (data: ArrayBuffer) => {
  };

  private socket: webSocket.WebSocket | undefined = undefined;
  private token: string = '';
  private state: ConnState = ConnState.Idle;
  private ackMode: boolean = false;

  getState(): ConnState {
    return this.state;
  }

  isConnected(): boolean {
    return this.socket !== undefined;
  }

  connect(host: string, port: number, token: string): void {
    this.disconnect();
    this.token = token;
    this.ackMode = false;

    const url: string = `ws://${host}:${port}`;
    this.setState(ConnState.Connecting, `正在连接 ${url} ...`);

    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = socket;

    socket.on('open', (err: BusinessError, value: Object) => {
      hilog.info(DOMAIN, TAG, 'socket opened: %{public}s', url);
      if (this.socket !== socket) {
        return;
      }
      this.setState(ConnState.Connected, `已连接 ${url}`);
      this.send(RemoteCmd.hello(this.token));
      this.send(RemoteCmd.sysInfo());
    });

    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value === 'string') {
        this.handleMessage(value);
      } else {
        this.onFrame(value);
      }
    });

    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      hilog.info(DOMAIN, TAG, 'socket closed: %{public}d %{public}s', value.code, value.reason);
      if (this.socket !== socket) {
        return;
      }
      this.socket = undefined;
      this.setState(ConnState.Closed, `连接已断开 (code ${value.code})`);
    });

    socket.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'socket error: %{public}d %{public}s', err.code, err.message);
      if (this.socket !== socket) {
        return;
      }
      this.socket = undefined;
      this.setState(ConnState.Error, this.describeError(err));
    });

    try {
      socket.connect(url, (err: BusinessError, value: boolean) => {
        if (err) {
          hilog.error(DOMAIN, TAG, 'connect failed: %{public}d %{public}s', err.code, err.message);
          if (this.socket !== socket) {
            return;
          }
          this.socket = undefined;
          this.setState(ConnState.Error, this.describeError(err));
        }
      });
    } catch (error) {
      this.socket = undefined;
      this.setState(ConnState.Error, '无法发起连接，请检查地址与端口');
    }
  }

  disconnect(): void {
    const socket: webSocket.WebSocket | undefined = this.socket;
    this.socket = undefined;
    if (socket !== undefined) {
      socket.off('open');
      socket.off('message');
      socket.off('close');
      socket.off('error');
      try {
        socket.close((err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'close failed: %{public}d', err.code);
          }
        });
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'close threw');
      }
    }
    this.setState(ConnState.Idle, '未连接');
  }

  send(data: string): boolean {    const socket: webSocket.WebSocket | undefined = this.socket;
    if (socket === undefined) {
      return false;
    }
    try {
      socket.send(data).then((value: boolean) => {
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'send failed: %{public}d %{public}s', err.code, err.message);
      });
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'send threw');
      return false;
    }
  }

  setStreaming(on: boolean, fps: number, quality: number, maxWidth: number): boolean {
    return this.send(RemoteCmd.stream(on, fps, quality, maxWidth));
  }

  ack(): void {
    if (this.ackMode) {
      this.send(RemoteCmd.ack());
    }
  }

  private setState(state: ConnState, detail: string): void {
    this.state = state;
    this.onState(state, detail);
  }

  private describeError(err: BusinessError): string {
    if (err.code === 200) {
      return '连接失败：该端口不是 WebSocket 服务，请确认电脑端已启动';
    }
    if (err.code === 2302003) {
      return '连接失败：已存在连接，请先断开';
    }
    const detail: string = err.message !== undefined && err.message.length > 0 ? err.message : '网络不可达';
    return `连接失败(${err.code}): ${detail}`;
  }

  private handleMessage(raw: string): void {
    let parsed: ServerMessage | undefined = undefined;
    try {
      parsed = JSON.parse(raw) as ServerMessage;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'invalid message: %{public}s', raw);
      return;
    }
    if (parsed !== undefined) {
      if (parsed.t === 'streamState') {
        this.ackMode = parsed.ackMode === true;
      }
      this.onMessage(parsed);
    }
  }
}
