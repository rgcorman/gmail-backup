#
# This script is intended to be executed by a user with administrative privileges
# for a Google Apps domain.
#
# Usage:
#   filter-mbox [options]
#
#   For list of options enter:   filter-mbox.rb --help
#
# Example:
#   filter-mbox --mboxFile="../test/mbox/roger1.mbox" --headers 
#
# To decrypt the downloaded mailboxes, use:
#    gpg --output roger2.mbox --decrypt roger2.mbox.encrypted
#    You will need to have the private key installed, and provide the passphrase.
#
# This script requires
#   the mail gem: gem install mail
#   the icalendar gem: gem install icalendar
#
require 'optparse'
require 'net/http'
require 'uri'
require 'rubygems'
require 'json'
require 'rest_client'
require 'rexml/document'
require 'io/console'
require 'Mail'
require 'icalendar'
require 'pathname'

include REXML

$options = 
  {:statusFile => "backup_status.txt",
   :accountsFile => "accounts.txt",
   :mboxFile => nil,
   :mailSummaryFile => nil,
   :meetingFile => nil,
   :maxMessages => 1000000,  # maximum messages to process
   :requests => [],
   :accounts => {},   # there may be a lot of these so use a hash
   :headers => false, # if true, output header lines at the start of the output crv files
   :debug => nil}

def processOptions
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: filter-mbox.rb [options]"

    opts.on('--mboxFile=mboxFile', 'Mbox decrypted file (from gmail-backup-status)') do |file|
      $options[:mboxFile] = file;
    end

    opts.on('--accountsFile=accountsFile', 'Accounts file (default: accounts.txt)') do |file|
      $options[:accountsFile] = file;
    end

    opts.on('--maxMessages=maxMessages', 'Maximum number of messages to process. Default: 1000000') do |m|
      $options[:maxMessages] = Integer(m);
    end
    
    opts.on('--headers', 'Generate headers in the output csv files') do
      $options[:headers] = true;
    end

    opts.on('-h', '--help', 'Displays Help') do
      puts opts
      exit
    end
  end

  ARGV.push('-h') if ARGV.empty?
  parser.parse! 
end  # processOptions

def getUserInput
end  # getUserInput

def inputAccountsFile
  file = File.open($options[:accountsFile], "r")
  count = 0
  file.each {|line|
    $options[:accounts][line.strip] = true; # add account domain to hash of accounts (as key). The value is arbitrary.
    count += 1
  }
  puts "Loaded " + count.to_s + " account domains"
  file.close
end

def getDomain(line)
  line = line.strip.downcase
  return nil unless line.length > 0
  parts = line.split "//"
  if parts.length == 2
    line = parts[1]
  end
  return nil if line.start_with? "http"
  if line.start_with? "www"
    line = (line.split ".", 2)[1]
  end
  if line.start_with? "m."
    line = (line.split ".", 2)[1]
  end
  line = (line.split "/", 2)[0]
  return nil if (line.length == 0 || (line.index ".") == nil ) 
  line
end

def convertHomepagesFile
  infile = File.open("homepages.txt", "r")
  outfile = File.open("domains.txt", "w")
  outfile.truncate 0
  infile.each {|line|
    line = getDomain line
    next unless line
    outfile << line << "\n"
    puts line
  }
  infile.close
  outfile.close
end

def init
  $options[:mailSummaryFile] = $options[:mboxFile]+".mail.csv"
  $options[:meetingFile] = $options[:mboxFile]+".meeting.csv"
  inputAccountsFile
end # init

$DEL = '^'

def getCalendarItems(msg)
  return [] unless msg.sender && (msg.sender.start_with? "calendar-notification")
  parser = Icalendar::Parser.new Base64.decode64 (msg.body.parts[1].body.raw_source)
  cals = parser.parse
  cal = cals[0]

  unless cal.nil?
    events = cal.events
    meetings = []
    events.each {|e|
      meeting = { :uid => e.uid,
                  :start => e.dtstart ? e.dtstart.strftime('%Y-%m-%dT%H:%M') : nil, 
                  :end => e.dtend ? e.dtend.strftime('%Y-%m-%dT%H:%M') : nil,              
                  :summary => e.summary, 
                  :location => e.location,
                  :organizer => e.organizer ? e.organizer.to : nil, 
                  :attendees => e.attendee.map {|a| a.to} }
      meetings << meeting 
    }
    meetings
  else
    []
  end
end

# takes a parsed message hash, and a delimiter character, and returns a string in csv format
def processMessage (msg, del)
  csv = ''
  msg.each {|k,v| 
    unless k == :meetings
      if v.kind_of?(Array)
        v.each {|a| csv << a.to_s.gsub("\n", " ").gsub(del, " ") << ";"}
      else
        csv << v.to_s.gsub("\n", " ").gsub(del, " ")
      end
      csv << del
    end
  }
  csv[0..-2]  # trim off last delimiter
end

def processMessageHeader(msg, del)
  csv = ''
  msg.each {|k,v| 
    unless k == :meetings
        csv << k.to_s << del
    end
  }
  csv[0..-2]  # trim off last delimiter
end

def processMeetings (msg, del)
  meetings = msg[:meetings]
  lines = []
  meetings.each {|m|
    csv = ''
    m.each {|k,v| 
      if v.kind_of?(Array)
        v.each {|a| csv << a.to_s.gsub("\n", " ").gsub(del, " ") << ";"}
      else
        csv << v.to_s.gsub("\n", " ").gsub(del, " ")
      end
      csv << del
    }
    lines << csv[0..-2] # trim off last delimiter
  }
  lines
end

def processMeetingHeader(msg, del)
  meeting = msg[:meetings][0]
  csv = ''
  meeting.each {|k,v| 
    csv << k.to_s << del
  }
  csv[0..-2]  # trim off last delimiter
end

# get the domain of an email address
def getEmailDomain(emailAddress)
  (emailAddress.split '@')[1]
end

#
# If the message contains an email address found in the accounts hash, return the message.
# Otherwise, return nil.
#
def retainMessage?(message)
  mailAddresses = message[:from] + message[:destinations]
  mailAddresses.each {|a|
    if $options[:accounts].has_key? getEmailDomain(a)
      return message
    end
  }

  # see if an attached meeting contains an account address
  meetings = message[:meetings]
  meetings.each do |m|
    addrs = m[:attendees] << m[:organizer]
    addrs.each {|a|
      if $options[:accounts].has_key? getEmailDomain(a)
        return message
      end
    }
  end unless meetings.nil?
  nil
end

#
# use the Mail class to parse the mail message.
# If there are any calendar items attached (.ics file) then include
# those, along with message headers we are interested in.
# Returns a hash containing the results, or nil if the message should not be logged.
#
def parseMessage (message)
  e = Mail.new message
  puts e.message_id
  meetings = getCalendarItems e
  email = { :message_id => e.message_id, 
            :date => e.date ? e.date.strftime('%Y-%m-%dT%H:%M') : nil, 
            :to => e.to, 
            :from => e.from, 
            :content_type => e.content_type,
            :sender => e.sender, 
            :subject => e.subject,
            :in_reply_to => e.in_reply_to, 
            :cc => e.cc, 
            :bcc => e.bcc, 
            :attachment? => e.attachments.length > 0, 
            :meetings => meetings, 
            :destinations => e.destinations }
   retainMessage?(email)
end

# Bit of monkey patching
class String
  def force_utf8
    if !self.valid_encoding?
      self.encode("UTF-8", :invalid=>:replace, :replace=>"?").encode('UTF-8')
    else
      self
    end
  end
end

#
# Assumes the passed file is open for read, and is positioned at the start
# if the first line of the message (first line following "From " line).
# Returns the whole message as a string.
#
def getNextMessage (file)
  message = ''
  while (line = file.gets)
    return message if (line.force_utf8.match(/\AFrom /))
    message << line
  end
  message.length == 0 ? nil : message
end

#
# Parse all the messages in the mailbox, and returns an array of extracted message objects
# Find the first line of the first message, and then call getNextMessage repeatedly until no more messages are found.
# Each message is passed to parseMessage, which returns a msg hash.
#
def parseMbox (path, outpath, meetpath, max = 1000000)
  file = File.open(path, "r")
  output = File.open(outpath, "w")
  output.truncate(0)
  meetings = File.open(meetpath, "w")
  meetings.truncate(0)
  showMailHeader = $options[:headers]
  showMeetingHeader = $options[:headers]
  
  while (line = file.gets)
    if (line.match(/\AFrom /)) #if we found a message
      while (max > 0 && message = getNextMessage(file))
        max -= 1
        m = parseMessage(message)
        if m
          if showMailHeader
            output << processMessageHeader(m, $DEL) << "\n"
            showMailHeader = false
          end
          output << processMessage(m, $DEL) << "\n"
          meetingLines = processMeetings(m, $DEL)
          meetingLines.each {|ml|
            if showMeetingHeader
              meetings << processMeetingHeader(m, $DEL) << "\n"
              showMeetingHeader = false
            end
            meetings << ml << "\n"
          }
        end
      end
    end
  end
  file.close
  output.close
  meetings.close
end
    
def main
  processOptions
  getUserInput
  init

  parseMbox $options[:mboxFile], $options[:mailSummaryFile], $options[:meetingFile], $options[:maxMessages]
end

###############
# run script

main

###############

