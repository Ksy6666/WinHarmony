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
  @State screenW: number = 0;
  @State screenH: number = 0;
  @State codec: string = '';

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
      const width: number = msg.sw ?? 0;
      const height: number = msg.sh ?? 0;
      const screen: string = `${width}x${height}`;
      this.infoText = `${hostName} ${userName} ${screen} ${serverName}`.trim();
      if (width > 0 && height > 0) {
        this.screenW = width;
        this.screenH = height;
        this.screenRatio = width / height;
      }
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
        this.screenW = width;
        this.screenH = height;
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
    this.codec = '';
    this.client.connect(target, portNumber, this.token);
  }

  private handleDisconnect(): void {
    this.client.disconnect();
    this.infoText = '';
    this.codec = '';
    this.screenW = 0;
    this.screenH = 0;
  }

  private handleSend(data: string): void {
    this.client.send(data);
  }

  private chooseCodec(codec: string): void {
    this.codec = codec;
  }

  @Builder
  codecPicker() {
    Column() {
      Column({ space: 14 }) {
        Text('选择画面编码')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#EAF0FF')
        Text('连接已建立，请选择电脑画面的传输编码方式')
          .fontSize(12)
          .fontColor('#7E88A8')

        Column({ space: 8 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('H.264 硬编码')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#EAF0FF')
              Text('带宽约为 JPEG 的 1/5 · 静止画面码率极低 · 支持 2K 高帧率 · 手机硬件解码')
                .fontSize(11)
                .fontColor('#7E88A8')
                .lineHeight(16)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor('#1A2136')
          .onClick(() => {
            this.chooseCodec('h264');
          })
        }
        .width('100%')

        Column({ space: 8 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('JPEG 兼容模式')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#EAF0FF')
              Text('每帧独立无依赖 · 网络波动时不花屏 · 带宽占用高 · 帧率受抓屏速度限制')
                .fontSize(11)
                .fontColor('#7E88A8')
                .lineHeight(16)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor('#1A2136')
          .onClick(() => {
            this.chooseCodec('jpeg');
          })
        }
        .width('100%')

        Button('取消并断开')
          .width('100%')
          .height(42)
          .fontSize(14)
          .backgroundColor('#2A3350')
          .onClick(() => {
            this.handleDisconnect();
            this.statusText = '已断开连接';
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding(22)
      .borderRadius(18)
      .backgroundColor('#111830')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
    .backgroundColor('rgba(5, 7, 14, 0.82)')
    .onClick(() => {
    })
  }

  build() {
    Column() {
      if (this.connState === ConnState.Connected) {
        if (this.codec.length > 0) {
          ControlPanel({
            host: this.host,
            port: this.port,
            infoText: this.infoText,
            isWide: this.isWide,
            screenRatio: this.screenRatio,
            screenW: this.screenW,
            screenH: this.screenH,
            codec: this.codec,
            client: this.client,
            onDisconnect: () => {
              this.handleDisconnect();
            },
            onSend: (data: string) => {
              this.handleSend(data);
            }
          })
        } else {
          this.codecPicker()
        }
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
