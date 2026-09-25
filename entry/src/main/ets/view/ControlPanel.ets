import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemoteCmd } from '../model/RemoteProtocol';
import { RemoteClient } from '../service/RemoteClient';

const DOMAIN: number = 0x0000;
const TAG: string = 'WinRemote';
const TAP_TOLERANCE_VP: number = 10;
const TAP_MAX_MS: number = 350;
const LONG_PRESS_MS: number = 420;

const TOUCH_IDLE: number = 0;
const TOUCH_POINTER: number = 1;
const TOUCH_SCROLL: number = 2;

const STATS_INTERVAL: number = 20;

const SCROLL_STEP_RATIO: number = 0.1;
const SCROLL_STEP_MIN_VP: number = 16;
const SCROLL_MAX_NOTCH_PER_EVENT: number = 12;

class KeyButton {
  label: string = '';
  kind: string = '';
  value: string = '';

  constructor(label: string, kind: string, value: string) {
    this.label = label;
    this.kind = kind;
    this.value = value;
  }
}

@Component
export struct ControlPanel {
  @Prop host: string = '';
  @Prop port: string = '';
  @Prop infoText: string = '';
  @Prop isWide: boolean = false;
  @Prop screenRatio: number = 1.7777778;
  onDisconnect: () => void = () => {
  };
  onSend: (data: string) => void = () => {
  };

  client: RemoteClient | undefined = undefined;

  @State frame: image.PixelMap | undefined = undefined;
  @State streaming: boolean = true;
  @State showPanel: boolean = false;
  @State padW: number = 1;
  @State padH: number = 1;
  @State draft: string = '';
  @State streamFps: number = 20;
  @State streamQuality: number = 70;
  @State streamMaxWidth: number = 1280;

  private resolutionOptions: number[] = [0, 1920, 1600, 1280];
  private fpsOptions: number[] = [10, 15, 20, 30, 60];
  private qualityOptions: number[] = [50, 70, 85];

  private pendingFrame: ArrayBuffer | undefined = undefined;
  private decoding: boolean = false;
  private statsFrames: number = 0;
  private statsDecodeTotal: number = 0;
  private statsDecodeMax: number = 0;
  private statsGapTotal: number = 0;
  private statsGapCount: number = 0;
  private statsRecv: number = 0;
  private statsBytes: number = 0;
  private statsDropped: number = 0;
  private lastArriveAt: number = 0;
  private downX: number = 0;
  private downY: number = 0;
  private downAt: number = 0;
  private dragged: boolean = false;
  private touchMode: number = TOUCH_IDLE;
  private longPressTimer: number = -1;
  private pressing: boolean = false;
  private scrollLastY: number = 0;
  private scrollStep: number = 40;
  private scrollAcc: number = 0;

  private keys: KeyButton[] = [
    new KeyButton('Enter', 'key', 'enter'),
    new KeyButton('Esc', 'key', 'esc'),
    new KeyButton('Tab', 'key', 'tab'),
    new KeyButton('退格', 'key', 'backspace'),
    new KeyButton('Del', 'key', 'delete'),
    new KeyButton('空格', 'key', 'space'),
    new KeyButton('↑', 'key', 'up'),
    new KeyButton('↓', 'key', 'down'),
    new KeyButton('←', 'key', 'left'),
    new KeyButton('→', 'key', 'right'),
    new KeyButton('Ctrl+C', 'combo', 'ctrl,c'),
    new KeyButton('Ctrl+V', 'combo', 'ctrl,v'),
    new KeyButton('Ctrl+X', 'combo', 'ctrl,x'),
    new KeyButton('Ctrl+A', 'combo', 'ctrl,a'),
    new KeyButton('Ctrl+Z', 'combo', 'ctrl,z'),
    new KeyButton('Alt+Tab', 'combo', 'alt,tab'),
    new KeyButton('Alt+F4', 'combo', 'alt,f4'),
    new KeyButton('Win', 'key', 'win'),
    new KeyButton('Win+D', 'combo', 'win,d'),
    new KeyButton('Win+E', 'combo', 'win,e'),
    new KeyButton('Win+L', 'combo', 'win,l'),
    new KeyButton('Ctrl+Shift+Esc', 'combo', 'ctrl,shift,esc')
  ];

  aboutToAppear(): void {
    const target: RemoteClient | undefined = this.client;
    if (target !== undefined) {
      target.onFrame = (data: ArrayBuffer) => {
        this.handleFrame(data);
      };
      this.applyStream(true);
    }
  }

  aboutToDisappear(): void {
    const target: RemoteClient | undefined = this.client;
    if (target !== undefined) {
      target.onFrame = (data: ArrayBuffer) => {
      };
      target.setStreaming(false, this.streamFps, this.streamQuality, this.streamMaxWidth);
    }
    const current: image.PixelMap | undefined = this.frame;
    if (current !== undefined) {
      current.release();
      this.frame = undefined;
    }
  }

  private applyStream(on: boolean): void {
    const target: RemoteClient | undefined = this.client;
    if (target !== undefined) {
      target.setStreaming(on, this.streamFps, this.streamQuality, this.streamMaxWidth);
    }
  }

  private resolutionLabel(value: number): string {
    return value === 0 ? '原生' : `${value}`;
  }

  private qualityLabel(value: number): string {
    if (value <= 50) {
      return '低';
    }
    if (value <= 70) {
      return '中';
    }
    return '高';
  }

  private handleFrame(data: ArrayBuffer): void {
    const now: number = Date.now();
    if (this.lastArriveAt > 0) {
      this.statsGapTotal += now - this.lastArriveAt;
      this.statsGapCount++;
    }
    this.lastArriveAt = now;
    this.statsRecv++;
    this.statsBytes += data.byteLength;
    if (this.decoding) {
      this.statsDropped++;
    }
    this.pendingFrame = data;
    if (!this.decoding) {
      this.decoding = true;
      this.decodeNext();
    }
  }

  private decodeNext(): void {
    const next: ArrayBuffer | undefined = this.pendingFrame;
    this.pendingFrame = undefined;
    if (next === undefined) {
      this.decoding = false;
      this.reportConsumed();
      return;
    }
    this.decode(next).then(() => {
      this.decodeNext();
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'frame decode failed: %{public}d %{public}s', err.code, err.message);
      this.decoding = false;
      this.reportConsumed();
    });
  }

  private reportConsumed(): void {
    const target: RemoteClient | undefined = this.client;
    if (target !== undefined) {
      target.ack();
    }
  }

  private async decode(data: ArrayBuffer): Promise<void> {
    const started: number = Date.now();
    const source: image.ImageSource = image.createImageSource(data);
    const pixelMap: image.PixelMap = await source.createPixelMap();
    const previous: image.PixelMap | undefined = this.frame;
    this.frame = pixelMap;
    if (previous !== undefined) {
      previous.release();
    }
    source.release();
    const cost: number = Date.now() - started;
    this.statsFrames++;
    this.statsDecodeTotal += cost;
    if (cost > this.statsDecodeMax) {
      this.statsDecodeMax = cost;
    }
    this.reportStats();
  }

  private reportStats(): void {
    if (this.statsFrames < STATS_INTERVAL) {
      return;
    }
    const decodeAvg: number = Math.round(this.statsDecodeTotal / this.statsFrames);
    const gapAvg: number = this.statsGapCount > 0
      ? Math.round(this.statsGapTotal / this.statsGapCount) : 0;
    const fps: number = gapAvg > 0 ? Math.round(1000 / gapAvg) : 0;
    const kb: number = this.statsRecv > 0
      ? Math.round(this.statsBytes / this.statsRecv / 1024) : 0;
    hilog.info(DOMAIN, TAG,
      'STATS frames=%{public}d decodeAvg=%{public}dms decodeMax=%{public}dms gapAvg=%{public}dms fps=%{public}d dropped=%{public}d kb=%{public}d',
      this.statsFrames, decodeAvg, this.statsDecodeMax, gapAvg, fps,
      this.statsDropped, kb);
    this.statsFrames = 0;
    this.statsDecodeTotal = 0;
    this.statsDecodeMax = 0;
    this.statsGapTotal = 0;
    this.statsGapCount = 0;
    this.statsRecv = 0;
    this.statsBytes = 0;
    this.statsDropped = 0;
  }

  private toggleStream(): void {
    const next: boolean = !this.streaming;
    this.streaming = next;
    this.applyStream(next);
    if (!next) {
      const current: image.PixelMap | undefined = this.frame;
      if (current !== undefined) {
        current.release();
        this.frame = undefined;
      }
    }
  }

  private sendAbsolute(localX: number, localY: number): void {
    const width: number = this.padW;
    const height: number = this.padH;
    if (width <= 1 || height <= 1) {
      return;
    }
    const containerRatio: number = width / height;
    let shownW: number = width;
    let shownH: number = height;
    let offsetX: number = 0;
    let offsetY: number = 0;
    if (this.screenRatio > containerRatio) {
      shownH = width / this.screenRatio;
      offsetY = (height - shownH) / 2;
    } else {
      shownW = height * this.screenRatio;
      offsetX = (width - shownW) / 2;
    }
    let nx: number = (localX - offsetX) / shownW;
    let ny: number = (localY - offsetY) / shownH;
    nx = nx < 0 ? 0 : (nx > 1 ? 1 : nx);
    ny = ny < 0 ? 0 : (ny > 1 ? 1 : ny);
    this.onSend(RemoteCmd.moveTo(nx, ny));
  }

  private handleScreenTouch(event: TouchEvent): void {
    const touches: TouchObject[] = event.touches;
    if (event.type === TouchType.Down) {
      if (touches.length >= 2) {
        this.beginScroll(touches);
        return;
      }
      if (touches.length === 1) {
        this.beginPointer(touches[0]);
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (this.touchMode === TOUCH_SCROLL) {
        this.updateScroll(touches);
        return;
      }
      if (this.touchMode !== TOUCH_POINTER || touches.length === 0) {
        return;
      }
      const point: TouchObject = touches[0];
      const travel: number = Math.abs(point.x - this.downX) + Math.abs(point.y - this.downY);
      if (travel > TAP_TOLERANCE_VP) {
        this.dragged = true;
        this.cancelLongPress();
      }
      this.sendAbsolute(point.x, point.y);
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.touchMode === TOUCH_SCROLL) {
        this.touchMode = TOUCH_IDLE;
        this.scrollAcc = 0;
        return;
      }
      if (this.touchMode !== TOUCH_POINTER) {
        return;
      }
      this.touchMode = TOUCH_IDLE;
      this.cancelLongPress();
      if (this.pressing) {
        this.pressing = false;
        this.onSend(RemoteCmd.release('left'));
        return;
      }
      const elapsed: number = Date.now() - this.downAt;
      if (!this.dragged && elapsed < TAP_MAX_MS) {
        this.onSend(RemoteCmd.click('left'));
      }
    }
  }

  private beginPointer(point: TouchObject): void {
    this.touchMode = TOUCH_POINTER;
    this.downX = point.x;
    this.downY = point.y;
    this.downAt = Date.now();
    this.dragged = false;
    this.cancelLongPress();
    this.sendAbsolute(point.x, point.y);
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = -1;
      if (this.touchMode !== TOUCH_POINTER || this.dragged || this.pressing) {
        return;
      }
      this.pressing = true;
      this.onSend(RemoteCmd.press('left'));
    }, LONG_PRESS_MS);
  }

  private cancelLongPress(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private beginScroll(touches: TouchObject[]): void {
    this.cancelLongPress();
    if (this.pressing) {
      this.pressing = false;
      this.onSend(RemoteCmd.release('left'));
    }
    this.touchMode = TOUCH_SCROLL;
    this.dragged = true;
    this.scrollStep = this.scrollStepForHeight();
    this.scrollAcc = 0;
    this.scrollLastY = this.averageY(touches, 0);
  }

  private updateScroll(touches: TouchObject[]): void {
    if (touches.length < 2) {
      return;
    }
    const currentY: number = this.averageY(touches, this.scrollLastY);
    const deltaY: number = currentY - this.scrollLastY;
    this.scrollLastY = currentY;
    this.scrollByVp(deltaY);
  }

  private averageY(touches: TouchObject[], fallback: number): number {
    let total: number = 0;
    let count: number = 0;
    for (let i = 0; i < touches.length; i++) {
      const item: TouchObject = touches[i];
      if (item.type === TouchType.Up || item.type === TouchType.Cancel) {
        continue;
      }
      total += item.y;
      count++;
    }
    if (count === 0) {
      return fallback;
    }
    return total / count;
  }

  private scrollStepForHeight(): number {
    const height: number = this.padH > 1 ? this.padH : 360;
    const step: number = height * SCROLL_STEP_RATIO;
    return step < SCROLL_STEP_MIN_VP ? SCROLL_STEP_MIN_VP : step;
  }

  private scrollByVp(deltaY: number): void {
    const limit: number = this.padH > 1 ? this.padH : 360;
    let vp: number = deltaY;
    if (vp > limit) {
      vp = limit;
    } else if (vp < -limit) {
      vp = -limit;
    }
    const step: number = this.scrollStep > SCROLL_STEP_MIN_VP ? this.scrollStep : SCROLL_STEP_MIN_VP;
    this.scrollAcc += -vp / step;
    let notches: number = Math.trunc(this.scrollAcc);
    if (notches === 0) {
      return;
    }
    if (notches > SCROLL_MAX_NOTCH_PER_EVENT) {
      notches = SCROLL_MAX_NOTCH_PER_EVENT;
    } else if (notches < -SCROLL_MAX_NOTCH_PER_EVENT) {
      notches = -SCROLL_MAX_NOTCH_PER_EVENT;
    }
    this.scrollAcc -= notches;
    this.onSend(RemoteCmd.scroll(notches));
  }

  private sendDraft(): void {
    const content: string = this.draft;
    if (content.length === 0) {
      return;
    }
    this.onSend(RemoteCmd.text(content));
    this.draft = '';
  }

  private trigger(item: KeyButton): void {
    if (item.kind === 'combo') {
      const parts: string[] = item.value.split(',');
      this.onSend(RemoteCmd.combo(parts));
    } else {
      this.onSend(RemoteCmd.key(item.value));
    }
  }

  @Builder
  header() {
    Row({ space: 6 }) {
      Circle({ width: 8, height: 8 })
        .fill('#3DDC84')
      Column({ space: 2 }) {
        Text(`已连接 ${this.host}:${this.port}`)
          .fontSize(13)
          .fontColor('#EAF0FF')
        Text(this.infoText.length > 0 ? this.infoText : '等待电脑信息...')
          .fontSize(10)
          .fontColor('#7E88A8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.streaming ? '暂停' : '播放')
        .height(32)
        .fontSize(11)
        .backgroundColor('#26304C')
        .onClick(() => {
          this.toggleStream();
        })
      Button(this.showPanel ? '收起' : '控制')
        .height(32)
        .fontSize(11)
        .backgroundColor(this.showPanel ? '#3D7BFF' : '#26304C')
        .onClick(() => {
          this.showPanel = !this.showPanel;
        })
      Button('断开')
        .height(32)
        .fontSize(11)
        .backgroundColor('#2A3350')
        .onClick(() => {
          this.onDisconnect();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ bottom: 10 })
  }

  @Builder
  screenArea() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.frame !== undefined) {
        Image(this.frame)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .interpolation(ImageInterpolation.Low)
          .draggable(false)
      } else {
        Column({ space: 6 }) {
          Text(this.streaming ? '正在获取电脑画面...' : '画面已暂停')
            .fontSize(14)
            .fontColor('#8FA0CC')
          Text('轻触=左键 · 拖动=移动鼠标 · 长按=按住左键 · 双指上下滑=滚轮')
            .fontSize(11)
            .fontColor('#5D6885')
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .backgroundColor('#05070E')
    .borderRadius(12)
    .clip(true)
    .onAreaChange((oldArea: Area, newArea: Area) => {
      if (typeof newArea.width === 'number') {
        this.padW = newArea.width;
      }
      if (typeof newArea.height === 'number') {
        this.padH = newArea.height;
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleScreenTouch(event);
    })
  }

  @Builder
  mouseButtons() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button('左键')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#26304C')
          .onClick(() => {
            this.onSend(RemoteCmd.click('left'));
          })
        Button('右键')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#26304C')
          .onClick(() => {
            this.onSend(RemoteCmd.click('right'));
          })
        Button('中键')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#26304C')
          .onClick(() => {
            this.onSend(RemoteCmd.click('middle'));
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('滚轮 ↑')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#26304C')
          .onClick(() => {
            this.onSend(RemoteCmd.scroll(3));
          })
        Button('滚轮 ↓')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor('#26304C')
          .onClick(() => {
            this.onSend(RemoteCmd.scroll(-3));
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  keyboard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.draft, placeholder: '输入要发送到电脑的文字' })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor('#FFFFFF')
          .caretColor('#FFFFFF')
          .backgroundColor('#1A2136')
          .borderRadius(8)
          .onChange((value: string) => {
            this.draft = value;
          })
          .onSubmit(() => {
            this.sendDraft();
          })
        Button('发送')
          .width(72)
          .height(40)
          .fontSize(14)
          .onClick(() => {
            this.sendDraft();
          })
      }
      .width('100%')

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.keys, (item: KeyButton) => {
          Button(item.label)
            .height(32)
            .fontSize(12)
            .backgroundColor('#26304C')
            .margin({ right: 6, bottom: 6 })
            .onClick(() => {
              this.trigger(item);
            })
        }, (item: KeyButton) => item.label)
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  streamSettings() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('分辨率')
          .fontSize(11)
          .fontColor('#5D6885')
          .width(46)
        ForEach(this.resolutionOptions, (option: number) => {
          Button(this.resolutionLabel(option))
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.streamMaxWidth === option ? '#3D7BFF' : '#26304C')
            .onClick(() => {
              this.streamMaxWidth = option;
              this.applyStream(this.streaming);
            })
        }, (option: number) => `res${option}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 6 }) {
        Text('帧率')
          .fontSize(11)
          .fontColor('#5D6885')
          .width(46)
        ForEach(this.fpsOptions, (option: number) => {
          Button(`${option}`)
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.streamFps === option ? '#3D7BFF' : '#26304C')
            .onClick(() => {
              this.streamFps = option;
              this.applyStream(this.streaming);
            })
        }, (option: number) => `fps${option}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 6 }) {
        Text('画质')
          .fontSize(11)
          .fontColor('#5D6885')
          .width(46)
        ForEach(this.qualityOptions, (option: number) => {
          Button(this.qualityLabel(option))
            .layoutWeight(1)
            .height(30)
            .fontSize(11)
            .backgroundColor(this.streamQuality === option ? '#3D7BFF' : '#26304C')
            .onClick(() => {
              this.streamQuality = option;
              this.applyStream(this.streaming);
            })
        }, (option: number) => `q${option}`)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('抓屏是瓶颈（本机约 40~70ms/帧），实测上限约 10~15fps')
        .fontSize(10)
        .fontColor('#48536E')
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
  }

  @Builder
  panelBody() {
    Column({ space: 10 }) {
      this.streamSettings()
      this.mouseButtons()
      this.keyboard()
    }
    .width('100%')
  }

  build() {
    Column() {
      this.header()
      if (this.isWide) {
        Row({ space: 12 }) {
          Column() {
            this.screenArea()
          }
          .layoutWeight(3)
          .height('100%')

          if (this.showPanel) {
            Scroll() {
              Column() {
                this.panelBody()
              }
              .width('100%')
            }
            .layoutWeight(2)
            .height('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Auto)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      } else {
        this.screenArea()
        if (this.showPanel) {
          Scroll() {
            Column() {
              this.panelBody()
            }
            .width('100%')
          }
          .width('100%')
          .height('42%')
          .align(Alignment.Top)
          .scrollBar(BarState.Auto)
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }
}
