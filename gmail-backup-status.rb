#!/usr/bin/env ruby
#
# This script is intended to be executed by a user with administrative privileges
# for a Google Apps domain.
#
# Usage:
#   gmail-backup-status [options]
#
#   For list of options enter:   gmail-backup-status.rb --help
#
# Example:
#   gmail-backup-status --domain=dealsignal.com --admin="roger@dealsignal.com" --debug 
#
#   gmail-backup-status --all --domain=dealsignal.com --admin="roger@dealsignal.com" --debug
#
# Prerequisites: 
#
# To decrypt the downloaded mailboxes, use:
#    gpg --output roger2.mbox --decrypt roger2.mbox.encrypted
#    You will need to have the private key installed, and provide the passphrase.
#
require 'optparse' 
require 'net/http'
require 'uri'
require 'rubygems'
require 'json'
require 'rest_client'
require 'rexml/document'
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
   :adminuser => nil,
   :adminpwd => nil,
   :requestIDs => [],
   :requestIDsFile => "RequestIDs.txt",
   :outputFile => "backup_status.txt",
   :results => [],
   :fromDate => nil,
   :all => nil,
   :debug => nil}

def processOptions
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: gmail-backup-status.rb [options]"

    opts.on('--domain=domain', 'Domain') do |domain|
      $options[:domain] = domain;
    end

    opts.on('--admin=adminuser', 'Admin user account') do |adminuser|
      $options[:adminuser] = adminuser;
    end

    opts.on('--all', 'Return all backup request status') do
      $options[:all] = true
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

  if $options[:adminuser] == nil
    print 'Admin user account name: '
    $options[:adminuser] = gets.chomp
  end

  if $options[:adminpwd] == nil
    print 'Admin user account password: '
    $options[:adminpwd] = STDIN.noecho(&:gets).strip
  end

end  # getUserInput

def inputRequestIDs
  if $options[:requestIDsFile]
    file = File.open($options[:requestIDsFile], "r")
    contents = ""
    file.each {|line|
      v = line.split ','
      h = { :requestID => v[0], :user => v[1].strip }
      $options[:requestIDs].push h
    }
    file.close
  end
end

def init
  inputRequestIDs
end # init

def gget (path)
  puts path
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


#
# Get user's mailbox backup status
#
def requestMboxStatus (user, requestID)
  resp = gget "/a/feeds/compliance/audit/mail/export/#{$options[:domain]}/#{user}/#{requestID}"
    rid, requestDate, status, fileUrl0, fileUrl1 = getResponseProps resp, ['requestId', 'requestDate', 'status', 'fileUrl0', 'fileUrl1']
  h = { :user => user, :requestID => rid, :requestDate => requestDate, :status => status, :fileUrl0 => fileUrl0, :fileUrl1 => fileUrl1 }
  puts h
  if $options[:debug]
    puts "requestMboxStatus response: "
    show_response resp
  end
  h
end

def outputResults
  if $options[:outputFile]
    output = open($options[:outputFile], "w")
    output.truncate(0)
    $options[:results].each {|r|
      output << (r[:requestID].to_s + "," + 
                 r[:user].to_s + "," + 
                 r[:requestDate].to_s + "," + 
                 r[:status].to_s + "," + 
                 r[:fileUrl0].to_s + "," +  
                 r[:fileUrl1].to_s +               
                 "\n")
    }
    output.close
  end
end

def getAllBackupRequests (fromDate)
  resp = gget ("/a/feeds/compliance/audit/mail/export/#{$options[:domain]}" + (fromDate ? ("?" + fromDate) : ""))
  # show_response resp

  doc = Document.new resp.body
  doc.root.elements.each {|e| 
    if e.name == 'entry'
      h = {}
      e.elements.each {|se| 
        if se.attributes['name']
          h[se.attributes['name']] = se.attributes['value']
        end
      }
      result = {}
      result[:requestID] = h["requestId"]
      result[:user] = h["userEmailAddress"]
      result[:requestDate] = h["requestDate"]
      result[:status] = h["status"]
      result[:fileUrl0] = h["fileUrl0"]
      result[:fileUrl1] = h["fileUrl1"]
      $options[:results].push result
      puts result
    end
  }
end

# get user's account info
# resp = gpost "/a/feeds/compliance/audit/account/#{$domain}/#{$user}", ""
    
def main
  processOptions
  getUserInput
    
  init
  $auth_token = get_auth_token $options[:adminuser], $options[:adminpwd]

  if $options[:debug]
      puts headers
      puts $options.merge({adminpwd: "HIDDEN"})
  end

  if $options[:all]
    getAllBackupRequests $options[:fromDate]
  else
  
    # request the users mailbox backup status
    $options[:requestIDs].each {|r|
      puts "Requesting mailbox status for user #{r[:user]}"
      results = requestMboxStatus r[:user], r[:requestID] 
      $options[:results].push results
    }
  end
  
  # output results for use later
  outputResults
  puts $options[:results]
  
end

###############
# run script

main

###############

