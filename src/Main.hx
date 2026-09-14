import net.GhostConnection;
import net.Util;
import net.EventConnection;
import net.NetConnection;
import net.MasterServerClient;
import net.NetInterface;
import datachannel.RTC;

class Main {
	public static function main() {
		var closing = false;

		RTC.init();

		#if sys
		var args = Sys.args();
		#else
		var args = [];
		#end

		var isServer = args[0] == "--host";

		NetInterface.setConfiguration("0.0.0.0", ["stun:stun.l.google.com:19302"], "ws://127.0.0.1:8080");

		if (isServer) {
			NetInterface.listen();
		} else {
			// fetch list
			var nc = new GhostConnection();
			NetInterface.getServerList((servers) -> {
				trace("Got server list");
				NetInterface.connect(servers[0].id, nc);
			});
		}
		#if hl
		// Loop only needed in native HL
		while (true) {
			MasterServerClient.process();
			NetInterface.processConnections();
			RTC.processEvents();
			if (closing)
				break;
		}
		#end
		RTC.finalize();
	}
}
