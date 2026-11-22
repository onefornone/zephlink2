// Zephlink relay.
//
// It does one small job: when two of YOUR devices cannot reach each other
// directly (for example your phone is on mobile data), it passes their
// messages along. Everything that goes through is already encrypted by the
// two devices before it gets here, and the relay has no keys, so it cannot
// read or change anything. It also stores nothing.
//
// Each pair of devices meets in a "room" whose name is a long secret code
// made by the two devices. Nobody else can guess it.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/room\/([0-9a-f]{64})$/);
    if (!match) {
      return new Response('Zephlink relay is running.', { status: 200 });
    }
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected a WebSocket connection.', { status: 426 });
    }
    const id = env.ROOMS.idFromName(match[1]);
    return env.ROOMS.get(id).fetch(request);
  },
};

export class Room {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const role =
      new URL(request.url).searchParams.get('role') === 'dial' ? 'dial' : 'wait';

    // The device that starts the link ("dial") is only let in when the other
    // one is already waiting. Otherwise it is told to try again later.
    if (role === 'dial' && this.state.getWebSockets('wait').length === 0) {
      return new Response('The other device is not here yet.', { status: 404 });
    }

    // Only one device per side. A newer connection replaces an older one.
    for (const old of this.state.getWebSockets(role)) {
      try {
        old.serializeAttachment({ replaced: true });
        old.close(1000, 'replaced');
      } catch (error) {
        // Already gone.
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server, [role]);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    const mine = this.state.getTags(ws)[0];
    const others = this.state.getWebSockets(mine === 'wait' ? 'dial' : 'wait');
    for (const target of others) {
      try {
        target.send(message);
      } catch (error) {
        // The other side just left.
      }
    }
  }

  webSocketClose(ws) {
    this.closeOthers(ws);
  }

  webSocketError(ws) {
    this.closeOthers(ws);
  }

  closeOthers(ws) {
    let attachment = null;
    try {
      attachment = ws.deserializeAttachment();
    } catch (error) {
      attachment = null;
    }
    if (attachment && attachment.replaced) return;
    for (const other of this.state.getWebSockets()) {
      if (other === ws) continue;
      try {
        other.close(1000, 'The other device left.');
      } catch (error) {
        // Already gone.
      }
    }
  }
}
