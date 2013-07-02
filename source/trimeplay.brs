' trimePlay
' This was written in less than a week after I decided I would really like to view photos from my recent holiday on my TV
' So don't expect that much ;)

' The key to understanding this nightmare of spaghetti is as follows:
' Brightscript is single-threaded. Therefore nothing may block
' Everything is a finite state machine. When data arrives on a socket then we look up the FSM for that socket, and call
' appropriate function to parse from (or write) to the socket.
' There are 4 kinds of these machines:
'   * UDP messages, which handle mDNS to announce the roku on the network. Handled in mdns.brs
'   * HTTP connections *from* the iDevice. These are like POST /play and GET /scrub. handled in http_reply.brs
'   * HTTP connection replies to messages sent via the reverse HTTP (typically these are not very interesting, but must be handled)
'   * HTTP connection replies to MP4 data requests. These are more interesting, and are handled in mp4.brs



Function Main()
    msgPort = createobject("roMessagePort") 
    m.mac = "CA:FE:BA:BE:FA:17"                 ' FIXME: fake?
    m.features = "3"
    'm.features = "0x39f7"
    ' Set up some stuff so we can display screens later in the http handlers
    m.port = msgPort
    m.state = "none"
    m.video_state = 0
    m.video_position = 0

    device_info = createobject("roDeviceInfo")
    m.display_size = device_info.getDisplaySize()

    default_screen = createobject("roImageCanvas")
    default_screen.SetMessagePort(msgPort)
    default_screen.SetLayer(0, {Color:"#FF000000", CompositionMode:"Source"}) 
    default_screen.SetLayer(1, {text:"Waiting for connection"
                           TextAttrs:{Color:"#FFCCCCCC", Font:"Medium",
                                     HAlign:"HCenter", VAlign:"VCenter",
                                  Direction:"LeftToRight"}
                                 TargetRect:{x:0,y:0,w:m.display_size.w,h:m.display_size.h}})

    default_screen.show()

    m.reversals = {}
    m.connections = {}
    m.sockets = {}
    http_requests = {}
    udp = createobject("roDatagramSocket")
    udp.setMessagePort(msgPort)

    udp_bind_addr = createobject("roSocketAddress")
    udp_bind_addr.setPort(5353)
    udp.setAddress(udp_bind_addr) 

    group = createobject("roSocketAddress")
    group.setHostName("224.0.0.251")
    result = udp.joinGroup(group)
    udp.setMulticastLoop(false)

    ' Set up the about-to-be-advertised TCP socket
    tcp = createobject("roStreamSocket")
    tcp.setMessagePort(msgPort)
    tcp_bind_addr = CreateObject("roSocketAddress")
    tcp_bind_addr.setPort(7000)
    tcp.setAddress(tcp_bind_addr)
    tcp.notifyReadable(true)
    tcp.listen(4)
    if not tcp.eOK() 
        print "Could not create TCP socket"
        stop
    end if

    ' Set up the unadvertised mirroring TCP socket just for fun
    mirror = createobject("roStreamSocket")
    mirror.setMessagePort(msgPort)
    mirror_bind_addr = CreateObject("roSocketAddress")
    mirror_bind_addr.setPort(7100)
    mirror.setAddress(mirror_bind_addr)
    mirror.notifyReadable(true)
    mirror.listen(4)
    if not mirror.eOK() 
        print "Could not create mirror TCP socket"
        stop
    end if


    ' Need to broadcast that we are an Apple TV, rather than just waiting to be polled. Sometimes this helps
    udp.setBroadcast(true)
    addr = createobject("roSocketAddress")
    addr.setPort(5353)
    addr.setHostName("224.0.0.251")
    udp.setSendToAddress(addr)
    announce = announce_packet()    
    print "Announcing our existence to the network"
    result = udp.send(announce, 0, announce.Count())
    udp.notifyReadable(true) 
    While true
        'print "Waiting in main loop"
        event = wait(0, msgPort)
        If type(event)="roSocketEvent"
            'print "Got event on " ; event.getSocketID()
            If event.getSocketID() = udp.getID()
                If udp.isReadable()
                   message = createobject("roByteArray")
                   size = udp.getCountRcvBuf()
                   ' Work around bug in upd.receive() :-S
                   message[size] = 0
                   message[size] = invalid
                   udp.receive(message, 0, size)
                   from = udp.getReceivedFromAddress()
                   'print "Received message of length " ; str(size) ; " from " ; from.getAddress()
                   dns = parse_dns(message)
                   respond_to_dns(dns, udp)
                End If
            Else If event.getSocketID() = tcp.getID()
                 client = tcp.accept()
                 If client = Invalid
                     print "Accept failed"                   
                 Else
                     client.notifyReadable(true)
                     client.setMessagePort(msgPort)
                     m.sockets[Stri(client.getID())] = client
                End If
            Else if event.getSocketID() = mirror.getID()
                 print "MIRRORING CONNECTION?"
                 client = mirror.accept()
                 If client = Invalid
                     print "Accept failed"                   
                 Else
                     client.notifyReadable(true)
                     client.setMessagePort(msgPort)
                     m.sockets[Stri(client.getID())] = client
                End If
            Else
                ' Must be a client connection!
                connection = m.sockets[Stri(event.getSocketID())]
                ' If connection is invalid, what does that mean?
                if connection <> invalid
                    ' FIXME: Is this still right since I added the mp4 stuff? Do we actually correctly close sockets?
                    if connection.isReadable() and connection.getCountRcvBuf() = 0 and not connection.isWritable() Then
                        ' Apparently this means the connection has been closed
                        ' What a terrible way to indicate it
                        print "Connection is closed"
                        connection.close()
                        m.sockets[Stri(event.getSocketID())] = invalid
                    Else
                        handle_tcp(connection)
                    End If
                else 
                    print "Invalid connection"
                    stop
                End If
            End If
        Else If type(event)="roVideoScreenEvent" Then
            if event.isStreamStarted()
               m.video_state = 1 ' playing
               send_event("state", "playing")
               m.video_position = event.GetIndex()
            else if event.isPlaybackPosition()
               m.video_position = event.GetIndex()
            else if event.isPaused()
               m.video_state = 2 'paused
               send_event("state", "paused")
            else if event.isResumed()
               send_event("state", "playing")
               m.video_state = 1 ' playing
            End If
            'print "Position is now "; m.video_position 
        Else
            print "Unexpected event: " ; type(event)
        End If
    End While
    udp.close()
End Function

Sub handle_tcp(connection as Object)
    request = m.connections[Stri(connection.getID())]
    If request = invalid Then
        ' An unsolicited request. Create an http handler for it
        request = create_new_request()        
        m.connections[Stri(connection.getID())] = request
    End if
    status = request.read_data(request, connection)
    If status = false Then ' More data is required
       return
    Else if status = true Then 'Data is complete. Execute handler
        ' Regardless of whether the socket is to be closed, the HTTP request has finished. We have to invalidate it here
        ' since the process_data() call might set up something else
        m.connections[Stri(connection.getID())] = invalid
        should_close = request.process_data(request, connection)
        if should_close then
            m.sockets[Stri(connection.getID())] = invalid
            connection.close()
        end if
    Else ' Error condition. Not handled (FIXME! Need to return ints instead of booleans so we have a third case. Or invalid?)
        stop
    End If
End Sub

Sub start_media(url as Object)
    ' Hokay. First, we don't even know the media type. Let's open a connection so we can ask about it
    print "Loading media parameters for " ; url
    socket = createobject("roStreamSocket")
    socket.setMessagePort(m.port)
    media_addr = CreateObject("roSocketAddress")
    media_addr.setPort(url.port)
    media_addr.setHostName(url.hostname)      
    request = create_new_request()
    m.connections[Stri(socket.getID())] = request
    m.sockets[Stri(socket.getID())] = socket
    ' Slightly confusing, but 'read data' also means 'when connected'. We change it once we have written the message
    request.read_data = get_media_type 
    request.process_data = invalid
    ' Also copy in some other stuff we need in a bit
    request.path = url.path
    request.hostname = url.hostname
    request.port = url.port
    socket.setSendToAddress(media_addr)
    socket.notifyReadable(true)
    socket.notifyWritable(true)
    socket.connect()
    ' And now we wait
End Sub

Function get_media_type(request as Object, socket as Object)
    reply = create_new_reply()
    reply.process_data = process_media_type

    ' Switch out the request for the reply
    GetGlobalAA().connections[Stri(socket.getID())] = reply

    ' But don't forget to copy across the important stuff
    reply.hostname = request.hostname
    reply.port = request.port
    reply.path = request.path

    packet = createobject("roByteArray")
    ' Originally I wanted to do HEAD here, and examine the content-type. Well, guess what? 
    ' iOS just disconnects if I ask for HEAD. Worse, everything is reported to be content-type: application/octet-stream. Great.
    msg = "GET " + request.path + " HTTP/1.1" + chr(13) + chr(10) + "Host: " + request.hostname + chr(13) + chr(10) + "Range: bytes=0-8" + chr(13) + chr(10) + chr(13) + chr(10)
    print msg
    socket.notifyWritable(false)
    packet.fromAsciiString(msg)
    print socket.send(packet, 0, packet.Count())
    return false ' Do not try to process media type yet, though, since we don't have it!
End Function

Function process_media_type(reply as Object, socket as Object)
    ' Heuristic time. First, if the header tells us, great
    if Lcase(reply.headers["content-type"]) = "something" then
        stop
    else
        ' Ok, so how about the body?
        if reply.body[4] = 102 and reply.body[5] = 116 and reply.body[6] = 121 and reply.body[7] = 112 then
            ' MP4 (probably)
            print "MP4 signature detected"
            load_mp4_file(reply, socket)
        else
            print "Unknown file type :("
            stop
        end if
    end if
    return false
End Function
