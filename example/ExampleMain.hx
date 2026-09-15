import net.GhostConnection;
import hxd.Key;
import haxe.Json;
import datachannel.RTCDataChannel;
import datachannel.RTCPeerConnection;
import datachannel.RTC;
import hxd.App;
import net.MasterServerClient;
import net.NetInterface;
import examplenet.TestConnection;

class ExampleMain extends App {
	override function init() {
		super.init();
		engine.backgroundColor = 0x202020;

		var font = hxd.res.DefaultFont.get();

		#if sys
		var args = Sys.args();
		#else
		var args = [];
		#end

		var isServer = args[0] == "--host";

		TestGame.instance = new TestGame(isServer);

		NetInterface.setConfiguration("0.0.0.0", ["stun:stun.l.google.com:19302"], "ws://127.0.0.1:8080");

		if (isServer) {
			NetInterface.listen();
		} else {
			// fetch list
			var nc = new TestConnection();
			NetInterface.getServerList((servers) -> {
				trace("Got server list");
				NetInterface.connect(servers[0].id, nc);
			});
		}

		RTC.init();
	}

	override function update(dt:Float) {
		super.update(dt);
		MasterServerClient.process();
		NetInterface.processConnections();
		TestGame.instance.update(dt);
		RTC.processEvents();
	}

	override function dispose() {
		RTC.finalize();
		super.dispose();
	}

	static function main() {
		new ExampleMain();
	}
}
