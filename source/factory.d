﻿/**
 * 
 * /home/tomas/workspace/mqtt-d/source/factory.d
 * 
 * Author:
 * Tomáš Chaloupka <chalucha@gmail.com>
 * 
 * Copyright (c) 2015 ${CopyrightHolder}
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
module mqttd.factory;

import std.string : format;
import std.range;

import mqttd.message;

version (unittest)
{
    import std.stdio;
}

enum bool canDecode(R) = isInputRange!R && isIntegral!(ElementType!R);

T deserialize(T, R)(auto ref R range) if (canDecode!R)
{
    import std.exception : enforce;

    // wrap it up to RefRange if needed to avoid problems with consuming different types of range
    static if (is(R == RefRange!TL, TL)) alias wrapped = range;
    else auto wrapped = refRange(&range);

    ubyte nextByte()
    {
        auto b = cast(ubyte)wrapped.front;
        range.popFront();
        return b;
    }

    T res;
    bool implemented = true;

    // read header if presented
    static if (__traits(hasMember, T, "header")) res.header = deserialize!FixedHeader(wrapped);

    static if (is(T == ubyte))
    {
        res = nextByte();
    }
    else static if (is(T == ushort))
    {
        res |= cast(ushort) (nextByte() << 8);
        res |= cast(ushort) nextByte();
    }
    else static if (is(T == string))
    {
        import std.array;
        import std.algorithm : map;

        auto length = deserialize!ushort(wrapped);
        res = wrapped.takeExactly(length).map!(a => cast(immutable char)a).array;
    }
    else static if (is(T == ConnectFlags))
    {
        res.flags = nextByte();
    }
    else static if (is(T == FixedHeader))
    {
        res.flags = nextByte();
        
        int multiplier = 1;
        ubyte digit;
        do
        {
            digit = nextByte();
            res.length += ((digit & 127) * multiplier);
            multiplier *= 128;
            if (multiplier > 128*128*128) throw new PacketFormatException("Malformed remaining length");
        } while ((digit & 128) != 0);
    }
    else static if (is(T == Connect))
    {
        res.protocolName = deserialize!string(wrapped);
        res.protocolLevel = deserialize!ubyte(wrapped);
        res.connectFlags = deserialize!ConnectFlags(wrapped);
        res.keepAlive = deserialize!ushort(wrapped);
        res.clientIdentifier = deserialize!string(wrapped);

        if (res.connectFlags.will)
        {
            res.willTopic = deserialize!string(wrapped);
            res.willMessage = deserialize!string(wrapped);
        }
        if (res.connectFlags.userName)
        {
            res.userName = deserialize!string(wrapped);
            if (res.connectFlags.password) res.password = deserialize!string(wrapped);
        }

        writeln(res);
        enforce(wrapped.empty, new PacketFormatException("There is more data available than specified in header"));
    }
    else implemented = false;

    if(implemented) 
    {
        // validate packet if header presented
        static if (__traits(hasMember, T, "header")) res.checkPacket();
        return res;
    }
    assert(0, "Not implemented deserialize for " ~ T.stringof);
}

void serialize(T)(T msg, scope void delegate(ubyte) sink)
{
    //set remaining packet length
    msg.setRemainingLength;

    //check if is valid
    try msg.checkPacket();
    catch (Exception ex) throw new PacketFormatException(format("'%s' packet is not valid: %s", T.stringof, ex.msg));

    msg.toBytes(sink);
}

/// Fixed header tests
unittest
{
   import std.array;
   
   assert(FixedHeader(PacketType.RESERVED1, true, QoSLevel.Reserved, true) == 0x0F);
   
   FixedHeader header = 0x0F;
   assert(header.type == PacketType.RESERVED1);
   assert(header.dup);
   assert(header.retain);
   assert(header.qos == QoSLevel.Reserved);
   
   header = FixedHeader(PacketType.CONNECT, 0x0F, 255);
   
   auto bytes = appender!(ubyte[]);
   header.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 3);
   assert(bytes.data[0] == 0x1F);
   assert(bytes.data[1] == 0xFF);
   assert(bytes.data[2] == 0x01);
   
   header.length = 10;
   bytes.clear();
   header.toBytes(a => bytes.put(a));
   assert(bytes.data.length == 2);
   assert(bytes.data[0] == 0x1F);
   assert(bytes.data[1] == 0x0A);
   
   header = deserialize!FixedHeader(cast(ubyte[])[0x1F, 0x0A]);
   assert(header.type == PacketType.CONNECT);
   assert(header.flags == 0x1F);
   assert(header.length == 10);
   
   header = deserialize!FixedHeader(cast(ubyte[])[0x20, 0x80, 0x02]);
   assert(header.type == PacketType.CONNACK);
   assert(header.flags == 0x20);
   assert(header.length == 256);
}

/// ubyte tests
unittest
{
   import std.array;
   
   ubyte id = 10;
   auto bytes = appender!(ubyte[]);
   id.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 1);
   assert(bytes.data[0] == 0x0A);
   
   id = 0x2B;
   bytes.clear();
   
   id.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 1);
   assert(bytes.data[0] == 0x2B);
   
   id = deserialize!ubyte([0x11]);
   assert(id == 0x11);
}

/// ushort tests
unittest
{
   import std.array;
   
   ushort id = 1;
   auto bytes = appender!(ubyte[]);
   id.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 2);
   assert(bytes.data[0] == 0);
   assert(bytes.data[1] == 1);
   
   id = 0x1A2B;
   bytes.clear();
   
   id.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 2);
   assert(bytes.data[0] == 0x1A);
   assert(bytes.data[1] == 0x2B);
   
   id = deserialize!ushort([0x11, 0x22]);
   assert(id == 0x1122);
}

/// string tests
unittest
{
   import std.array;
   import std.string : representation;
   import std.range;
   
   auto name = "test";
   auto bytes = appender!(ubyte[]);
   name.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 6);
   assert(bytes.data[0] == 0);
   assert(bytes.data[1] == 4);
   assert(bytes.data[2..$] == "test".representation);
   
   name = deserialize!string(cast(ubyte[])[0x00, 0x0A] ~ "randomname".representation);
   assert(name == "randomname");
   
   auto range = inputRangeObject(cast(ubyte[])[0x00, 0x04] ~ "MQTT".representation);
   name = deserialize!string(range);
   assert(name == "MQTT");
}

/// ConnectFlags test
unittest
{
   import std.array;
   
   ConnectFlags flags;
   
   assert(flags == ConnectFlags(false, false, false, QoSLevel.AtMostOnce, false, false));
   assert(flags == 0);
   
   flags = 1; //reserved - no change
   assert(flags == ConnectFlags(false, false, false, QoSLevel.AtMostOnce, false, false));
   assert(flags == 0);
   
   flags = 2;
   assert(flags == ConnectFlags(false, false, false, QoSLevel.AtMostOnce, false, true));
   
   flags = 4;
   assert(flags == ConnectFlags(false, false, false, QoSLevel.AtMostOnce, true, false));
   
   flags = 24;
   assert(flags == ConnectFlags(false, false, false, QoSLevel.Reserved, false, false));
   
   flags = 32;
   assert(flags == ConnectFlags(false, false, true, QoSLevel.AtMostOnce, false, false));
   
   flags = 64;
   assert(flags == ConnectFlags(false, true, false, QoSLevel.AtMostOnce, false, false));
   
   flags = 128;
   assert(flags == ConnectFlags(true, false, false, QoSLevel.AtMostOnce, false, false));
   
   auto bytes = appender!(ubyte[]);
   flags.toBytes(a => bytes.put(a));
   
   assert(bytes.data.length == 1);
   assert(bytes.data[0] == 128);
   
   flags = deserialize!ConnectFlags([2]);
   assert(flags.cleanSession);
}

/// Connect message tests
unittest
{
    import std.array;

    auto con = Connect();
    con.clientIdentifier = "testclient";
    con.connectFlags.userName = true;
    con.userName = "user";

    auto buffer = appender!(ubyte[]);

    serialize(con, (ubyte a) { /*writef("%.2x ", a);*/ buffer.put(a); });

    assert(buffer.data.length == 30);

    assert(buffer.data == cast(ubyte[])[
            0x10, //fixed header
            0x1c, // rest is 30
            0x00, 0x04, //length of MQTT text
            0x4d, 0x51, 0x54, 0x54, // MQTT
            0x04, //protocol level
            0x80, //just user name flag
            0x00, 0x00, //zero keepalive
            0x00, 0x0a, //length of client identifier
            0x74, 0x65, 0x73, 0x74, 0x63, 0x6c, 0x69, 0x65, 0x6e, 0x74, //testclient text
            0x00, 0x04, //username length
            0x75, 0x73, 0x65, 0x72 //user text
        ]);

    //auto con2 = deserialize!Connect(buffer.data);
    auto con2 = deserialize!Connect(tee!(a=>writef("%.02x ", a))(buffer.data));
	writeln();
	writeln(con2);
    assert(con == con2);
}
