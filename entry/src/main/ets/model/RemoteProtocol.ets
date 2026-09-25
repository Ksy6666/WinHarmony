export enum ConnState {
  Idle = 0,
  Connecting = 1,
  Connected = 2,
  Closed = 3,
  Error = 4
}

export interface ServerMessage {
  t?: string;
  ok?: boolean;
  msg?: string;
  server?: string;
  host?: string;
  user?: string;
  os?: string;
  sw?: number;
  sh?: number;
  ts?: number;
  needToken?: boolean;
  on?: boolean;
  fps?: number;
  quality?: number;
  maxWidth?: number;
  ackMode?: boolean;
  screenW?: number;
  screenH?: number;
  backend?: string;
}

class StreamPayload {
  t: string = 'stream';
  on: boolean = true;
  fps: number = 6;
  quality: number = 55;
  maxWidth: number = 1024;
  ack: boolean = true;
}

class HelloPayload {
  t: string = 'hello';
  token: string = '';
  client: string = 'harmony';
}

class ComboPayload {
  t: string = 'combo';
  keys: string[] = [];
}

class TextPayload {
  t: string = 'text';
  s: string = '';
}

export class RemoteCmd {
  static hello(token: string): string {
    const payload: HelloPayload = new HelloPayload();
    payload.token = token;
    return JSON.stringify(payload);
  }

  static move(dx: number, dy: number): string {
    return `{"t":"move","dx":${Math.round(dx)},"dy":${Math.round(dy)}}`;
  }

  static moveTo(x: number, y: number): string {
    return `{"t":"moveto","x":${x},"y":${y}}`;
  }

  static click(button: string): string {
    return RemoteCmd.button(button, 'click');
  }

  static button(button: string, action: string): string {
    return `{"t":"click","b":"${button}","a":"${action}"}`;
  }

  static press(button: string): string {
    return RemoteCmd.button(button, 'down');
  }

  static release(button: string): string {
    return RemoteCmd.button(button, 'up');
  }

  static scroll(dy: number): string {
    return `{"t":"scroll","dx":0,"dy":${Math.round(dy)}}`;
  }

  static key(name: string): string {
    return `{"t":"key","k":"${name}"}`;
  }

  static combo(keys: string[]): string {
    const payload: ComboPayload = new ComboPayload();
    payload.keys = keys;
    return JSON.stringify(payload);
  }

  static text(content: string): string {
    const payload: TextPayload = new TextPayload();
    payload.s = content;
    return JSON.stringify(payload);
  }

  static sysInfo(): string {
    return '{"t":"sysinfo"}';
  }

  static stream(on: boolean, fps: number, quality: number, maxWidth: number): string {
    const payload: StreamPayload = new StreamPayload();
    payload.on = on;
    payload.fps = fps;
    payload.quality = quality;
    payload.maxWidth = maxWidth;
    return JSON.stringify(payload);
  }

  static ping(): string {
    return '{"t":"ping"}';
  }

  static ack(): string {
    return '{"t":"ack"}';
  }
}
