@Component
export struct ConnectPanel {
  @Link host: string;
  @Link port: string;
  @Link token: string;
  @Prop statusText: string = '';
  @Prop connected: boolean = false;
  @Prop busy: boolean = false;
  onConnect: () => void = () => {
  };

  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor('#7E88A8')
      .width('100%')
      .textAlign(TextAlign.Start)
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          Column({ space: 6 }) {
            Text('WinRemote')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor('#EAF0FF')
            Text('局域网遥控 Windows 11 · 鼠标 / 键盘')
              .fontSize(13)
              .fontColor('#7E88A8')
          }
          .margin({ top: 40, bottom: 24 })

        Column({ space: 14 }) {
          Column({ space: 6 }) {
            this.fieldLabel('电脑内网地址')
            TextInput({ text: this.host, placeholder: '电脑的局域网 IP，如 192.168.1.23' })
              .height(46)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .caretColor('#FFFFFF')
              .enabled(!this.busy)
              .onChange((value: string) => {
                this.host = value;
              })
          }
          .width('100%')

          Column({ space: 6 }) {
            this.fieldLabel('端口')
            TextInput({ text: this.port, placeholder: '8765' })
              .type(InputType.Number)
              .height(46)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .caretColor('#FFFFFF')
              .enabled(!this.busy)
              .onChange((value: string) => {
                this.port = value;
              })
          }
          .width('100%')

          Column({ space: 6 }) {
            this.fieldLabel('访问令牌（服务端 --token，可留空）')
            TextInput({ text: this.token, placeholder: '可留空' })
              .type(InputType.Password)
              .height(46)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .caretColor('#FFFFFF')
              .enabled(!this.busy)
              .onChange((value: string) => {
                this.token = value;
              })
          }
          .width('100%')
        }
        .width('100%')

        Row({ space: 10 }) {
          Circle({ width: 8, height: 8 })
            .fill(this.connected ? '#3DDC84' : '#FF7A7A')
          Text(this.statusText)
            .fontSize(13)
            .fontColor('#A9B3D0')
            .layoutWeight(1)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 22 })

        Button(this.busy ? '连接中...' : '连接')
          .width('100%')
          .height(48)
          .fontSize(16)
          .enabled(!this.busy)
          .margin({ top: 18 })
          .onClick(() => {
            this.onConnect();
          })

        Blank()

        Text('在电脑上运行 server/winremote_server.py 后，输入它打印出的局域网地址')
          .fontSize(11)
          .fontColor('#48536E')
          .textAlign(TextAlign.Center)
          .margin({ top: 20, bottom: 20 })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 560, maxHeight: '100%' })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
