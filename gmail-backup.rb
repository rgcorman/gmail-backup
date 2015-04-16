#!/usr/bin/env ruby
#
# This script is intended to be executed by a user with administrative privileges
# for a Google Apps domain.
# It allows Google mail backups to be made for a specified set of users.
# This script does necessary preparation, and instructs Gmail to prepare
# the backups. It then quits, and another script will be run to locate
# the backups and check on their status.
#
# Usage:
#   gmail-backup [options]
#
#   For list of options enter:   gmail-backup,rb --help
#
# Example:
#   gmail-backup --domain=dealsignal.com --users "users.txt" --admin="roger@dealsignal.com" --publickey="public-key.txt" --startDate="2013-04-01" --debug  
#
# Prerequisites: 
#
#
require 'optparse' 
require 'net/http'
require 'uri'
require 'rubygems'
require 'json'
require 'rest_client'
require 'rexml/document'
require 'base64'
require 'io/console'

include REXML

CLIENT_LOGIN_URI = URI.parse('https://www.google.com/accounts/ClientLogin')
CLIENT_LOGIN_HEADERS = {'Content-type' => 'application/x-www-form-urlencoded'}
SERVICE = 'apps'
ACCOUNT_TYPE = 'HOSTED'
SOURCE = 'dealsignal-gmailextract-0.0.1'

$URI = URI.parse('https://apps-apis.google.com')
$auth_token = nil

def headers 
  { 'Content-Type' => 'application/atom+xml',
    'Authorization' => "GoogleLogin auth=\"#{$auth_token}\"" }
end

$options = 
  {:domain => nil, 
   :userfile => nil, 
   :headersonly => nil, 
   :adminuser => nil,
   :adminpwd => nil,
   :publickeyfile => nil,
   :publickey => nil,
   :users => [],
   :requestIDs => [],
   :startDate => nil,
   :endDate => nil,
   :outputFile => "RequestIDs.txt",
   :debug => nil}

def processOptions
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: gmail-backup.rb [options]"

    opts.on('--domain=domain', 'Domain') do |domain|
      $options[:domain] = domain;
    end

    opts.on('--users=userfile', 'User file pathname') do |userfile|
      $options[:userfile] = userfile; 
    end

    opts.on('--headersonly', 'Backup headers only') do
      $options[:headersonly] = true;
    end

    opts.on('--admin=adminuser', 'Admin user account') do |adminuser|
      $options[:adminuser] = adminuser;
    end

    opts.on('--publickey=publickeyfile', 'Public key file path') do |publickeyfile|
      $options[:publickeyfile] = publickeyfile;
    end

    opts.on('--startdate=startdate', 'Start date for backup') do |startdate|
      $options[:startDate] = startdate;
    end

    opts.on('--debug', 'Turn on development/debug messages') do
      $options[:debug] = true;
    end

    opts.on('-h', '--help', 'Displays Help') do
      puts opts
      exit
    end
  end
  
  parser.parse! 
end  # processOptions

def getUserInput
  if $options[:domain] == nil
    print 'Domain: '
    $options[:domain] = gets.chomp
  end

  if $options[:userfile] == nil
    print 'User file path: '
    $options[:userfile] = gets.chomp
  end

  if $options[:adminuser] == nil
    print 'Admin user account name: '
    $options[:adminuser] = gets.chomp
  end

  if $options[:adminpwd] == nil
    print 'Admin user account password: '
    $options[:adminpwd] = STDIN.noecho(&:gets)
  end

end  # getUserInput

def init 

  #
  # Load the public key into a string, if one was specified
  #
  if $options[:publickeyfile]
    public_key_contents = File.read($options[:publickeyfile])
    public_key_contents_base64 = Base64.encode64(public_key_contents)
    $options[:publickey] = public_key_contents_base64
  end

  #
  # load the list of users whose email is being backed up
  #
  if $options[:userfile]
    file = File.open($options[:userfile], "r")
    contents = ""
    file.each {|line|
      $options[:users].push line.strip
    }
    file.close
  end
end # init

def gget (path)
  http = Net::HTTP.new($URI.host, $URI.port)
  http.use_ssl = true
  resp, data = http.get2(path, headers)
  resp
end

def gpost (path, payload)
  http = Net::HTTP.new($URI.host, $URI.port)
  http.use_ssl = true
  resp, data = http.post(path, payload, headers)
  resp
end

#
# Given and HTTP response object and an array of property names (strings),
# find and return the values associated with the properties
#
def getResponseProps (resp, props)
  doc = Document.new resp.body
  results = []
  props.each { |s|
    doc.root.elements.each {|e| 
      if e.attributes['name'] && e.attributes['name'] == s
        results << e.attributes['value']
        break
      end
    }
  }
  results 
end

def show_response (resp)
  doc = Document.new resp.body
  doc.root.elements.each {|e| puts e }
  resp
end

def get_auth_token(email, password, logintoken=nil, logincaptcha=nil)
  params = {
    :accountType => ACCOUNT_TYPE,
    :Email => email,
    :Passwd => password,
    :service => SERVICE,
    :source => SOURCE,
    :logintoken => logintoken,
    :logincaptcha => logincaptcha
  }

  resp = RestClient.post(CLIENT_LOGIN_URI.to_s, params, CLIENT_LOGIN_HEADERS)
  lines = resp.body.split("\n")
  auth_line = lines.find {|l| l =~ /^Auth=.*/i}
  auth_line.sub(/^Auth=/i, '')
end 

def uploadPublicKey
  if $options[:publickey]
    resp = gpost "/a/feeds/compliance/audit/publickey/#{$options[:domain]}",
      "<atom:entry xmlns:atom='http://www.w3.org/2005/Atom' xmlns:apps='http://schemas.google.com/apps/2006'>
         <apps:property name=\"publicKey\" value=\"#{$options[:publickey]}\"/>
       </atom:entry>"
  end
  if $options[:debug]
    puts "uploadPublicKey response: "
    show_response resp
  end
end

#
# Request user's email mbox, returns the request ID from Google
#
def requestUserMbox (user)
  resp = gpost "/a/feeds/compliance/audit/mail/export/#{$options[:domain]}/#{user}",
    "<atom:entry xmlns:atom='http://www.w3.org/2005/Atom' xmlns:apps='http://schemas.google.com/apps/2006'>
       <apps:property name='beginDate' value=\"#{$options[:startDate] ? $options[:startDate] + ' 00:00' : ''}\"/>
       <apps:property name='endDate' value=\"#{$options[:endDate] ? $options[:endDate] + ' 00:00' : ''}\"/>
       <apps:property name='includeDeleted' value='true'/>
       <apps:property name='searchQuery' value=''/>
       <apps:property name='packageContent' value=\"#{$options[:headersonly] ? 'HEADER_ONLY' : 'FULL_MESSAGE'}\"/>
     </atom:entry>"
  if $options[:debug]
    puts "requestUserMbox response: "
    show_response resp
  end
  doc = Document.new resp.body # parse response body to get request ID

  requestID = doc.root.elements.each {|e| 
    if e.attributes['name'] && e.attributes['name'] == 'requestId'
      break e.attributes['value']
    end
  }
end

def outputRequestIDs
  if $options[:outputFile]
    output = open($options[:outputFile], "w")
    output.truncate(0)
    p $options[:requestIDs]
    $options[:requestIDs].each {|r|
      next if Array === r[:requestID]
      output << (r[:requestID] + "," + r[:user] +"\n")
    }
    output.close
  end
end
    
def main
  processOptions
  getUserInput
  
  if $options[:debug]
      puts headers
      puts $options.merge({adminpwd: "HIDDEN"})
  end
  
  init
  $auth_token = get_auth_token $options[:adminuser], $options[:adminpwd]
  uploadPublicKey

 
  # request the users mailboxes, and store responses
  $options[:users].each {|u|
    puts "Requesting mailbox for user #{u}"
    requestID = requestUserMbox u
    h = { :requestID => requestID, :user => u }
    $options[:requestIDs].push h
    puts requestID 
  }
  
  # output results for use later
  outputRequestIDs

end

###############
# run script

main

###############

