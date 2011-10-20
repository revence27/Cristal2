require 'rubygems'
require 'json'
require 'socket'
require 'thread'

module Cristal
    class LoginFailure < Exception
    end

    class SendFailure < Exception
    end

    class Connection
        attr_writer :cona
        def initialize sck, hst
            @sck  = sck
            @hst  = hst
            @rsd  = nil
            @cona = {}
        end

        def get
            got = @sck.gets
            if got then
                ans = JSON.parse got
                if ans['facility'] != 'process' then
                    STDERR.puts(%[What? #{ans.inspect}  ?])
                else
                    ans
                end
            end
        rescue Exception => e
            STDERR.puts(e.message)
            nil
        rescue Errno::EPIPE => e
            STDERR.puts('Peer has vanished.')
            nil
        end

        def reprocess! from, to, msg
            @rsd ||= TCPSocket.open(@hst, reentrance)
            @rsd.puts({:facility => :process, :params =>
                      {:to => to, :from => from, :message => msg}}.to_json)
        end

        def reentrance
            @cona['reentrance']
        end

        def shortcode
            @cona['shortcode']
        end

        def [] x
            @cona[x]
        end

        def send snd, rcp, msg
            return send(snd, [rcp], msg) unless rcp.class == Array
            @sck.puts({:facility => :send, :params =>
                      {:to => rcp, :from => snd, :message => msg}}.to_json)
        end
    end

    class Cristal
        def self.connect hst, prt, kwd, pwd
            TCPSocket.open(hst, prt) do |sck|
                con = Connection.new sck, hst
                sck.puts(%[{"facility":"login", "params":{"keyword":] +
                    %[#{kwd.inspect}, "password":#{pwd.inspect}, ] +
                    %["pwdscheme":"pwd"}}])
                rsp = JSON.parse(sck.gets)
                if rsp['facility'] == 'proceed' then
                    con.cona = rsp['params']
                    ans      = yield con
                    sck.puts %[{"facility":"logout"}]
                    ans
                else
                    coz = rsp['params']['message']
                    raise LoginFailure.new(%[Log in failed for #{kwd}: #{coz}])
                end
            end
        end
    end


    #   Okay, a new interface. I hate the above one. Let's see if I can make a
    #   neater one.
    
    #   Class to be extended for thingy to work.
    class CristalSession
        def initialize hst, prt, logdt
            @host, @port, @logdt = hst, prt, logdt
        end

        def start
            TCPSocket.open(@host, @port) do |sck|
                sck.puts({:facility => 'login', :params =>
                         {:keyword => @logdt[:keyword],
                          :password => @logdt[:password],
                          :pwdscheme => 'pwd'}}.to_json)
                rsp = JSON.parse(sck.gets)
                @reentrance = rsp['params']['reentrance']
                @shortcode  = rsp['params']['shortcode']
                if rsp['facility'] == 'proceed' then
                    begin
                        while true
                            dat = JSON.parse(sck.gets)
                            if dat['facility'] != 'process' then
                                break
                            else
                                got = process(dat['params'])
                                deal_with_messages(sck, got) if got
                            end
                        end
                        finish sck
                    rescue Exception => e
                        finish sck
                        raise e
                    end
                elsif rsp['facility'] == 'error'
                    failed_auth(rsp['params'])
                end
            end
        end

        def finish sck
            sck.puts({:facility => 'logout'}.to_json)
        end

        def failed_auth pars
            raise LoginFailure.new(pars['message'])
        end

        def deal_with_messages sck, rep
            return deal_wth_messages([rep]) if rep.class != Array
            rep.each do |msg|
                msg[:to]     = [msg[:to]] if msg[:to].class != Array
                msg[:from] ||= @shortcode
                sck.puts({:facility => 'send', :params => msg}.to_json)
            end
        end
    end
end
