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
require 'io/console'
require 'pathname'

$options =
    {:statusFile => "backup_status.txt",
     :requests => [],
     :passphrase => nil,
     :decrypt => false,
     :debug => false}

#
# Generate a system call to gpg to decrypt the file
#
def decrypt_command (inputPath, outputPath)
  "gpg --batch --yes --passphrase #{$options[:passphrase].strip} -o #{outputPath} -d #{inputPath}"
end

def processOptions
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: download-mbox.rb [options]"

    opts.on('--debug', 'Show development/debug information') do
      $options[:debug] = true;
    end

    opts.on('--decrypt', 'Decrypt downloaded files using private key') do
      $options[:decrypt] = true;
    end

    opts.on('-h', '--help', 'Displays Help') do
      puts opts
      exit
    end
  end

  parser.parse!
end  # processOptions

def getUserInput
  if $options[:passphrase] == nil && $options[:decrypt]
    print 'Private key passphrase: '
    $options[:passphrase] = STDIN.noecho(&:gets)
    puts ""
  end
end  # getUserInput

def inputStatusFile
  if $options[:statusFile]
    file = File.open($options[:statusFile], "r")
    contents = ""
    file.each {|line|
      v = line.split ','
      h = { :requestID => v[0], :email => v[1], :requestedDate => v[2], :status => v[3].strip }
      h[:user] = h[:email].split("@")[0]
      if v.length > 4
        h[:fileUrl0] = v[4].strip
      end
      if v.length > 5
        h[:fileUrl1] = v[5].strip
      end

      $options[:requests].push h
      if $options[:debug]
        puts h
      end
    }
    file.close
  end
end

#
# downloads a large binary file in chunks, and saves it to disk
#
def downloadUrl(url, outputPath)
  if $options[:debug]
    puts "Downloading url #{url} to path #{outputPath}"
  end
  uri = URI.parse(url)
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    request = Net::HTTP::Get.new uri.path
    http.request request do |response|
      open outputPath, 'wb' do |io|
        response.read_body do |chunk|
          io.write chunk
        end
      end
    end
  end
end

def downloadBackups
  $options[:requests].each { |req|
    encryptedPath = "#{req[:user]}_#{req[:requestID]}.pgp"
    decryptedPath = "#{req[:user]}_#{req[:requestID]}.mbox"

    # download the encrypted mbox file
    if req[:status] == 'COMPLETED' && req[:fileUrl0]
      puts "Downloading #{encryptedPath}"
      downloadUrl(req[:fileUrl0], encryptedPath)

      if $options[:decrypt]
        # decrypt the downloaded file
        puts "Decrypting #{encryptedPath}"
        system(decrypt_command(encryptedPath, decryptedPath))
      end
    end
  }
end

def init
  inputStatusFile
end # init

def main
  processOptions
  getUserInput
  init

  downloadBackups
end

###############
# run script

main

###############

