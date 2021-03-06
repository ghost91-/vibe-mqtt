﻿/**
 *
 * /home/tomas/workspace/mqtt-d/source/mqttd/tests.d
 *
 * Author:
 * Tomáš Chaloupka <chalucha@gmail.com>
 *
 * Copyright (c) 2015 Tomáš Chaloupka
 *
 * Boost Software License 1.0 (BSL-1.0)
 *
 * Permission is hereby granted, free of charge, to any person or organization obtaining a copy
 * of the software and accompanying documentation covered by this license (the "Software") to use,
 * reproduce, display, distribute, execute, and transmit the Software, and to prepare derivative
 * works of the Software, and to permit third-parties to whom the Software is furnished to do so,
 * all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including the above license
 * grant, this restriction and the following disclaimer, must be included in all copies of the Software,
 * in whole or in part, and all derivative works of the Software, unless such copies or derivative works
 * are solely in the form of machine-executable object code generated by a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 * PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR ANYONE
 * DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */
module mqttd.tests;

version (unittest):

import std.array;
import std.stdio;
import mqttd;
import mqttd.serialization;

@safe:

/// ubyte tests
unittest
{
	ubyte id = 10;
	auto wr = serializer(appender!(ubyte[]));
	wr.write(id);

	assert(wr.data.length == 1);
	assert(wr.data[0] == 0x0A);

	id = 0x2B;
	wr.clear();
	wr.write(id);

	assert(wr.data.length == 1);
	assert(wr.data[0] == 0x2B);

	id = deserializer([0x11]).read!ubyte();
	assert(id == 0x11);

	id = [0x22].deserializer.read!ubyte();
	assert(id == 0x22);
}

/// ushort tests
unittest
{
	ushort id = 1;
	auto wr = serializer(appender!(ubyte[]));
	wr.write(id);

	assert(wr.data.length == 2);
	assert(wr.data[0] == 0);
	assert(wr.data[1] == 1);

	id = 0x1A2B;
	wr.clear();
	wr.write(id);

	assert(wr.data.length == 2);
	assert(wr.data[0] == 0x1A);
	assert(wr.data[1] == 0x2B);

	id = [0x11, 0x22].deserializer.read!ushort();
	assert(id == 0x1122);
}

/// string tests
unittest
{
	import std.string : representation;

	auto name = "test";
	auto wr = serializer(appender!(ubyte[]));
	wr.write(name);

	assert(wr.data.length == 6);
	assert(wr.data[0] == 0);
	assert(wr.data[1] == 4);
	assert(wr.data[2..$] == "test".representation);

	name = (cast(ubyte[])[0x00, 0x0A] ~ "randomname".representation).deserializer.read!string();
	assert(name == "randomname");
}

/// Fixed header tests
unittest
{
	assert(FixedHeader(PacketType.RESERVED1, true, QoSLevel.Reserved, true) == 0x0F);

	FixedHeader header = 0x0F;
	assert(header.type == PacketType.RESERVED1);
	assert(header.dup);
	assert(header.retain);
	assert(header.qos == QoSLevel.Reserved);

	header = FixedHeader(PacketType.CONNECT, 0x0F, 255);

	auto wr = serializer(appender!(ubyte[]));
	wr.write(header);

	assert(wr.data.length == 3);
	assert(wr.data[0] == 0x1F);
	assert(wr.data[1] == 0xFF);
	assert(wr.data[2] == 0x01);

	header.length = 10;
	wr.clear();
	wr.write(header);
	assert(wr.data.length == 2);
	assert(wr.data[0] == 0x1F);
	assert(wr.data[1] == 0x0A);

	header = [0x1F, 0x0A].deserializer.read!FixedHeader();
	assert(header.type == PacketType.CONNECT);
	assert(header.flags == 0x1F);
	assert(header.length == 10);

	header = [0x20, 0x80, 0x02].deserializer.read!FixedHeader();
	assert(header.type == PacketType.CONNACK);
	assert(header.flags == 0x20);
	assert(header.length == 256);
}

/// ConnectFlags test
unittest
{
	ConnectFlags flags = ConnectFlags(128);

	auto wr = serializer(appender!(ubyte[]));
	wr.write(flags);

	assert(wr.data.length == 1);
	assert(wr.data[0] == 128);

	flags = [2].deserializer.read!ConnectFlags();
	assert(flags.cleanSession);
}

/// Connect message tests
unittest
{
	ubyte[] data = [
		0x10, //fixed header
		0x1c, // rest is 28
		0x00, 0x04, //length of MQTT text
		'M', 'Q', 'T', 'T', // MQTT
		0x04, //protocol level
		0x80, //just user name flag
		0x00, 0x00, //zero keepalive
		0x00, 0x0a, //length of client identifier
		't', 'e', 's', 't', 'c', 'l', 'i', 'e', 'n', 't', //testclient text
		0x00, 0x04, //username length
		'u', 's', 'e', 'r' //user text
	];

	auto con = Connect();
	con.clientIdentifier = "testclient";
	con.flags.userName = true;
	con.userName = "user";

	auto wr = appender!(ubyte[]);
	wr.serialize(con);

	assert(wr.data.length == 30);

	//debug writefln("%(%.02x %)", wr.data);
	assert(wr.data == data);

	auto con2 = wr.data.deserialize!Connect();
	//auto con2 = deserialize!Connect(data);
	assert(con == con2);
}

unittest
{
	ubyte[] data = [
		0x20, //fixed header
		0x02, //rest is 2
		0x00, //flags
		0x00  //return code
	];
	ubyte[] data2 = [
		0x20, //fixed header
		0x02, //rest is 2
		0x01, //flags
		0x05  //return code
	];

	auto conack = ConnAck();

	auto wr = appender!(ubyte[]);
	wr.serialize(conack);

	assert(wr.data.length == 4);

	//debug writefln("%(%.02x %)", wr.data);
	assert(wr.data == data);

	auto conack2 = wr.data.deserialize!ConnAck();

	// TODO: this for some reason fails..
	//    writefln("%(%.02x %)", *(cast(byte[ConnAck.sizeof]*)(&conack)));
	//    writefln("%(%.02x %)", *(cast(byte[ConnAck.sizeof]*)(&conack2)));
	//    assert(conack == conack2);
	assert(conack.header == conack2.header);
	assert(conack.flags == conack2.flags);
	assert(conack.returnCode == conack2.returnCode);
	assert(conack.returnCode == ConnectReturnCode.ConnectionAccepted);

	conack2.flags = 0x01;
	conack2.returnCode = ConnectReturnCode.NotAuthorized;
	wr.clear();

	wr.serialize(conack2);

	assert(wr.data.length == 4);
	assert(wr.data == data2);
}

unittest
{
	ubyte[] data = [
		0x33, //fixed header
		0x12, //rest is 18
		0x00, 0x09, //topic length
		'/', 'r', 'o', 'o', 't', '/', 's', 'e', 'c', //filter text
		0xab, 0xcd,  //packet id
		0x01, 0x2, 0x3, 0x4, 0x5 //payload
	];

	auto pub = Publish();
	pub.header.qos = QoSLevel.QoS1;
	pub.header.retain = true;
	pub.packetId = 0xabcd;
	pub.topic = "/root/sec";
	pub.payload = [1, 2, 3, 4, 5];

	auto wr = appender!(ubyte[]).serialize(pub);

	// debug writefln("%(%.02x %)", wr.data);
	assert(wr.data.length == 20);

	assert(wr.data == data);

	auto pub2 = wr.data.deserialize!Publish();
	assert(pub == pub2);
}

unittest
{
	void testPubx(T)(ubyte header)
	{
		ubyte[] data = [
			header, //fixed header
			0x02, //rest is 2
			0x00, 0x00  //packet id
		];

		ubyte[] data2 = [
			header, //fixed header
			0x02, //rest is 2
			0xab, 0xcd  //packet id
		];

		auto px = T();

		auto wr = appender!(ubyte[]);
		wr.serialize(px);

		assert(wr.data.length == 4);

		//debug writefln("%(%.02x %)", wr.data);
		assert(wr.data == data);

		auto px2 = wr.data.deserialize!T();

		//TODO: Fails but are same
		//assert(px == px2);
		assert(px.header == px2.header);
		assert(px.packetId == px2.packetId);

		px2.packetId = 0xabcd;
		wr.clear();

		wr.serialize(px2);

		assert(wr.data.length == 4);
		assert(wr.data == data2);
	}

	testPubx!PubAck(0x40);
	testPubx!PubRec(0x50);
	testPubx!PubRel(0x62);
	testPubx!PubComp(0x70);
	testPubx!UnsubAck(0xb0);
}

unittest
{
	ubyte[] data = [
		0x82, //fixed header
		0x0c, //rest is 12
		0xab, 0xcd,  //packet id
		0x00, 0x07, //filter length
		'/', 'r', 'o', 'o', 't', '/', '*', //filter text
		0x02 //qos
	];

	auto sub = Subscribe();
	sub.packetId = 0xabcd;
	sub.topics ~= Topic("/root/*", QoSLevel.QoS2);

	auto wr = appender!(ubyte[]);
	wr.serialize(sub);

	assert(wr.data.length == 14);

	//debug writefln("%(%.02x %)", wr.data);
	assert(wr.data == data);

	auto sub2 = wr.data.deserialize!Subscribe();
	assert(sub == sub2);
}

unittest
{
	ubyte[] data = [
		0x90, //fixed header
		0x06, //rest is 2
		0xab, 0xcd,  //packet id
		0x00, 0x01, 0x02, 0x80 //ret codes
	];

	auto suback = SubAck();
	suback.packetId = 0xabcd;
	suback.returnCodes ~= QoSLevel.QoS0;
	suback.returnCodes ~= QoSLevel.QoS1;
	suback.returnCodes ~= QoSLevel.QoS2;
	suback.returnCodes ~= QoSLevel.Failure;

	auto wr = appender!(ubyte[]);
	wr.serialize(suback);

	assert(wr.data.length == 8);

	//debug writefln("%(%.02x %)", wr.data);
	assert(wr.data == data);

	auto suback2 = wr.data.deserialize!SubAck();
	assert(suback == suback2);
}

unittest
{
	ubyte[] data = [
		0xa2, //fixed header
		0x0b, //rest is 11
		0xab, 0xcd,  //packet id
		0x00, 0x07, //filter length
		'/', 'r', 'o', 'o', 't', '/', '*' //filter text
	];

	auto unsub = Unsubscribe();
	unsub.packetId = 0xabcd;
	unsub.topics ~= "/root/*";

	auto wr = appender!(ubyte[]);
	wr.serialize(unsub);

	//debug writefln("%(%.02x %)", wr.data);
	assert(wr.data.length == 13);
	assert(wr.data == data);

	auto unsub2 = wr.data.deserialize!Unsubscribe();
	assert(unsub == unsub2);
}

unittest
{
	void testSimple(T)(ubyte header)
	{
		auto s = T();

		auto wr = appender!(ubyte[]);
		wr.serialize(s);

		assert(wr.data.length == 2);

		//debug writefln("%(%.02x %)", wr.data);
		assert(wr.data == cast(ubyte[])[header, 0x00]);

		auto s2 = wr.data.deserialize!T();

		assert(s.header == s2.header);

		wr.clear();
		wr.serialize(s2);

		assert(wr.data.length == 2);
		assert(wr.data == cast(ubyte[])[header, 0x00]);
	}

	testSimple!PingReq(0xc0);
	testSimple!PingResp(0xd0);
	testSimple!Disconnect(0xe0);
}
