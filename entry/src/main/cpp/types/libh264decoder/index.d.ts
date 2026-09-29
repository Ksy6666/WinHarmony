export const createDecoder: (surfaceId: string, width: number, height: number) => boolean;
export const pushFrame: (data: ArrayBuffer) => boolean;
export const releaseDecoder: () => void;
export const setRenderCallback: (callback: () => void) => void;
