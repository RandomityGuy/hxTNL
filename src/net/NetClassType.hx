package net;

enum abstract NetClassType(Int) from Int to Int {
	var ClassNone;
	var ClassObject;
	var ClassDataBlock;
	var ClassEvent;
	var ClassConnection;
	var ClassCount;
}
