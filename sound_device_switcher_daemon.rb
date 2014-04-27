#!/usr/bin/env ruby

=begin
    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
=end

class SoundDeviceSwitcherDaemon
  USB_SPEAKER = "USB Audio DAC"
  INTERNAL_SPEAKER = "HDA Intel PCH"

  DEVICE_MONITOR_COMMAND="pactl subscribe"
  SINK_LIST_COMMAND="pacmd list-sinks"
  INPUT_LIST_COMMAND = "pacmd list-sink-inputs"
  SET_DEFAULT_SINK_COMMAND = "pacmd set-default-sink"
  CHANGE_LIVE_SINK_COMMAND = "pacmd move-sink-input"
  JACK_AVAILABILITY_COMMAND = "pactl list sinks"

  def initialize
    @jack_connected = nil
    @sinks = {}
  end

  def monitor_device(&block)
    IO.popen(DEVICE_MONITOR_COMMAND) do |io|
      while(line=io.gets)
        begin
          if line =~ /^Event 'change' on sink #(\d+)/
            yield(:sink, $1.to_i)
          elsif line =~ /^Event 'new' on sink #(\d+)/
            yield(:new, $1.to_i)
          elsif line =~ /^Event 'remove' on sink #(\d+)/
            yield(:remove, $1.to_i)
          end
        rescue => e
          puts e.backtrace
          puts "Exception caught."
          exit 1
        end
      end
    end
  end

  def setup_sink_info
    alsa_card_name = nil
    current_device = nil
    IO.popen(SINK_LIST_COMMAND) do |io|
      while line=io.gets
        if line =~ /index:\s+(\d+)/
          dev = $1.to_i
          # new device
          if current_device
            if alsa_card_name.nil?
              raise "Could not retrieve Alsa card name for sink #{current_device}."
            end
            @sinks[alsa_card_name] = {
              :index => current_device,
            }
            
            alsa_card_name = nil
          end
          current_device = dev
        end
        
        if line =~ /alsa\.card_name\s+=\s+"(.+)"/
          alsa_card_name = $1
        end
      end
      if current_device
        if alsa_card_name.nil?
          raise "Could not retrieve Alsa card name for sink #{current_device}."
        end
        @sinks[alsa_card_name] = {
          :index => current_device,
        }
      end
    end
  end

  def remove_sink(sink)
    @sinks.delete_if do |k, v|
      v[:index] == sink
    end
  end

  def head_phone_connected?
    sinks = []
    current_sink = nil
    IO.popen(JACK_AVAILABILITY_COMMAND) do |io|
      while line=io.gets
        if line =~ /Sink #(\d+)/
          current_sink = $1.to_i
          next
        elsif not current_sink.nil?
          if line =~ /headphones.+available/i and line !~ /not available/
            sinks.push(current_sink)
          end
        end
      end
    end
    sinks.size > 0
  end

  def internal_sink
    sink = @sinks[INTERNAL_SPEAKER]
    if sink.nil?
      raise "Sink for head phone is not found."
    end
    sink[:index]
  end

  def usb_sink
    (sink = @sinks[USB_SPEAKER]).nil? ? nil : sink[:index]
  end

  def get_sink_inputs
    inputs = []
    IO.popen(INPUT_LIST_COMMAND) do |io|
      while line=io.gets
        if line =~ /index:\s*(\d+)/
          inputs.push($1.to_i)
        end
      end
    end
    inputs
  end

  def use_sink(sink)
    get_sink_inputs.each do |i|
      cmd = "#{CHANGE_LIVE_SINK_COMMAND} #{i} #{sink}"
      system(cmd)
    end
    cmd = "#{SET_DEFAULT_SINK_COMMAND} #{sink}"
    system(cmd)
  end

  def use_head_phone
    use_sink(internal_sink)
  end

  def use_usb
    use_sink(usb_sink)
  end
  
  def run
    setup_sink_info
    monitor_device do |type, sink|
      case type
      when :sink
        if sink == internal_sink and not usb_sink.nil?
          if head_phone_connected?
            use_head_phone
          else
            use_usb
          end
        end
      when :new
        setup_sink_info
      when :remove
        remove_sink(sink)
      end
    end
  end
end

if __FILE__ == $0
  SoundDeviceSwitcherDaemon.new.run()
end
