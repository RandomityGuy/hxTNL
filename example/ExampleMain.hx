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
	public static var instance:ExampleMain;

	override function init() {
		super.init();
		engine.backgroundColor = 0x202020;

		instance = this;

		var font = hxd.res.DefaultFont.get();

		#if sys
		var args = Sys.args();
		#else
		var args = [];
		#end

		var isServer = args[0] == "--host";

		TestGame.instance = new TestGame(isServer, s2d);

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

	override function render(e:h3d.Engine) {
		super.render(e);

		#if hl
		e.driver.present();
		#end
	}

	static function main() {
		new ExampleMain();
	}
}
