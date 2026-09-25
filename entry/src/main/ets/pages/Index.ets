import { ConnState, ServerMessage } from '../model/RemoteProtocol';
import { RemoteClient } from '../service/RemoteClient';
import { ConnectPanel } from '../view/ConnectPanel';
import { ControlPanel } from '../view/ControlPanel';

const WIDE_BREAKPOINT_VP: number = 600;

@Entry
@Component
struct Index {
  @State host: string = '';
  @State port: string = '8765';
  @State token: string = '';
  @State connState: ConnState = ConnState.Idle;
  @State statusText: string = '未连接';
  @State infoText: string = '';
  @State isWide: boolean = false;
  @State screenRatio: number = 1.7777778;

  private client: RemoteClient = new RemoteClient();

  aboutToAppear(): void {
    this.client.onState = (state: ConnState, detail: string) => {
      this.connState = state;
      if (detail.length > 0) {
        this.statusText = detail;
      }
    };
    this.client.onMessage = (msg: ServerMessage) => {
      this.applyMessage(msg);
    };
  }

  aboutToDisappear(): void {
    this.client.disconnect();
  }

  onBackPress(): boolean {
    if (this.connState === ConnState.Connected || this.connState === ConnState.Connecting) {
      this.handleDisconnect();
      this.statusText = '已断开连接';
      return true;
    }
    return false;
  }

  private applyMessage(msg: ServerMessage): void {
    const kind: string = msg.t ?? '';
    if (kind === 'hello' || kind === 'info') {
      if (msg.ok === false) {
        this.statusText = msg.msg ?? '电脑拒绝了连接';
        return;
      }
      const hostName: string = msg.host ?? '';
      const userName: string = msg.user ?? '';
      const serverName: string = msg.server ?? '';
      const screen: string = `${msg.sw ?? 0}x${msg.sh ?? 0}`;
      this.infoText = `${hostName} ${userName} ${screen} ${serverName}`.trim();
      return;
    }
    if (kind === 'err') {
      this.statusText = `错误: ${msg.msg ?? ''}`;
      return;
    }
    if (kind === 'streamState') {
      const width: number = msg.screenW ?? 0;
      const height: number = msg.screenH ?? 0;
      if (width > 0 && height > 0) {
        this.screenRatio = width / height;
      }
      return;
    }
    if (kind === 'textResult' && msg.ok !== true) {
      this.statusText = '文字发送失败，可改用 Ctrl+V 粘贴';
    }
  }

  private handleConnect(): void {
    const target: string = this.host.trim();
    const portNumber: number = Number(this.port);
    if (target.length === 0 || !(portNumber >= 1 && portNumber <= 65535)) {
      this.statusText = '请填写正确的内网地址和端口';
      return;
    }
    this.infoText = '';
    this.client.connect(target, portNumber, this.token);
  }

  private handleDisconnect(): void {
    this.client.disconnect();
    this.infoText = '';
  }

  private handleSend(data: string): void {
    this.client.send(data);
  }

  build() {
    Column() {
      if (this.connState === ConnState.Connected) {
        ControlPanel({
          host: this.host,
          port: this.port,
          infoText: this.infoText,
          isWide: this.isWide,
          screenRatio: this.screenRatio,
          client: this.client,
          onDisconnect: () => {
            this.handleDisconnect();
          },
          onSend: (data: string) => {
            this.handleSend(data);
          }
        })
      } else {
        ConnectPanel({
          host: this.host,
          port: this.port,
          token: this.token,
          statusText: this.statusText,
          connected: false,
          busy: this.connState === ConnState.Connecting,
          onConnect: () => {
            this.handleConnect();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1020')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      let availableVp: number = 0;
      if (typeof newArea.width === 'number') {
        availableVp = newArea.width;
      }
      const wide: boolean = availableVp >= WIDE_BREAKPOINT_VP;
      if (wide !== this.isWide) {
        this.isWide = wide;
      }
    })
  }
}
