# frozen_string_literal: true
require 'zip'
require 'zlib'
require 'rubygems/package'
require 'digest'

class Nested
  # a weird hack to get a nested method call working like I want it to
  def myreader(zipfile)


class Preparsing
  include Sidekiq::Worker
  # only retry 10 times - after that, the genotyping probably has already been deleted
  sidekiq_options queue: :preparse, retry: 10, unique: true

  def perform(genotype_id)
    genotype = Genotype.find(genotype_id)

    logger.info "Starting preparse on #{genotype.genotype.path}"
    # First, we need to find out which archive or flat text our uploaded file is!
    # We use the bash tool file for that
    #
    # There are two possible outcomes - file is a collection of files (tar, tar.gz, zip)
    # or file is a single file (ASCII, gz)
    filetype = %x{file #{genotype.genotype.path}}
    case filetype
    when /ASCII text/
      logger.info "File is flat text"
      reader = File.method("open")
      is_collection = False
    when /gzip compressed data, was/
      reader = Zlib::GzipReader.method("open")
      logger.info "File is gz"
      is_collection = False
    when /gzip compressed data, last modified/
      reader = lambda { |zipfile| Gem::Package::TarReader.new(Zlib::GzipReader.open(zipfile)) }
      is_collection = True
    when /POSIX tar archive/
      logger.info "File is tar"
      reader = Gem::Package::TarReader.method("new")
      is_collection = True
    when /Zip archive data/
      logger.info "File is zip"
      reader = Zip::File.method("open")
      is_collection = True
    end


    if is_collection
      # Find the biggest file in the archive
      biggest = ''
      biggest_size = 0
      reader.call genotype.genotype.path do |zipfile|
        # find the biggest file, since that's going to be the genotyping
        zipfile.each do |entry|
          if entry.size > biggest_size
            biggest = entry
            biggest_size = entry.size
          end
        end

        zipfile.extract(biggest,"#{Rails.root}/tmp/#{genotype.fs_filename}.csv")
        system("mv #{Rails.root}/tmp/#{genotype.fs_filename}.csv #{Rails.root}/public/data/#{genotype.fs_filename}")
        logger.info "copied file"
      end
    else
      system("cp #{genotype.genotype.path} #{Rails.root}/public/data/#{genotype.fs_filename}")
    end

    # now that they are unzipped, check if they're actually proper files
    file_is_ok = false
    fh = File.open "#{Rails.root}/public/data/#{genotype.fs_filename}"
    l = fh.readline()
    # some files, for some reason, start with the UTF-BOM-marker
    l = l.sub("\uFEFF","")
    # iterate as long as there's commenting going on
    while l.start_with?("#")
      l = fh.readline()
      l = l.sub("\uFEFF","")
    end

    if genotype.filetype == "23andme"
      # first non-comment line is of length 4 after split
      if l.strip.split("\t").length == 4
        logger.info "file is 23andme and is ok!"
        file_is_ok = true
      end
    elsif genotype.filetype == "genes-for-good"
      # first non-comment line is of length 4 after split
      if l.strip.split("\t").length == 4
        logger.info "file is genes-for-good and is ok!"
        file_is_ok = true
      end
    elsif genotype.filetype == "ancestry"
      # first line is of length 5
      if l.strip.split("\t").length == 5
        file_is_ok = true
        logger.info "file is ancestry and is ok!"
      end
    elsif genotype.filetype == "decodeme"
      # first line is of length 6
      if l.strip.split(",").length == 6
        file_is_ok = true
        logger.info "file is decodeme and is ok!"
      end
    elsif genotype.filetype == "ftdna-illumina"
      # first line is of length 4
      if l.strip.split(",").length == 4
        file_is_ok = true
        logger.info "file is ftdna and is ok!"
      end
    elsif genotype.filetype == "23andme-exome-vcf"
      #first line is
      if l.strip.split("\t").length == 10
        file_is_ok = true
        logger.info "file is 23andme-exome and is ok!"
      end
    elsif genotype.filetype == "IYG"
      if l.strip.split("\t").length == 2
        file_is_ok = true
        logger.info "file is IYG and is ok!"
      end
    end

    logger.info "Checking whether genotyping is duplicate"
    md5 = Digest::MD5.file("#{Rails.root}/public/data/#{genotype.fs_filename}").to_s
    file_is_duplicate = false
    if Genotype.unscoped.where(md5sum: md5).where.not(id: genotype.id).count.positive?
      file_is_duplicate = true
      logger.info "Genotyping #{genotype.genotype.path} is already uploaded!\n"
      logger.info "Genotyping #{genotype.fs_filename} has the same md5sum.\n"
      file_is_ok = false
      file_is_duplicate = true
    end

    logger.info "Checking whether genotyping contains email addresses"
    # this should be the fastest way to do it
    cmd = "LANG=C grep -F '@' #{Rails.root}/public/data/#{genotype.fs_filename}"
    matches = system( cmd )

    file_has_mails = false
    if matches
      logger.info "Genotyping #{genotype.genotype.path} contains email addresses!"
      file_is_ok = false
      file_has_mails = true
    end

    # not proper file!
    if not file_is_ok
      if file_is_duplicate
        UserMailer.duplicate_file(genotype.user_id).deliver_later
        system("rm #{Rails.root}/public/data/#{genotype.fs_filename}")
        Genotype.find_by_id(genotype.id).delete
      elsif file_has_mails
        UserMailer.file_has_mails(genotype.user_id).deliver
        system("rm #{Rails.root}/public/data/#{genotype.fs_filename}")
        Genotype.find_by_id(genotype.id).delete
      else
        UserMailer.parsing_error(genotype.user_id).deliver_later
        logger.info "file is not ok, sending email"
        system("rm #{Rails.root}/public/data/#{genotype.fs_filename}")
        Genotype.find_by_id(genotype.id).delete
      end
    else
      logger.info "Updating genotype with md5sum #{md5}"
      logger.info "Updating genotype #{genotype.id}"
      status = genotype.update_attributes(md5sum: md5)
      logger.info "Md5-updating-status is #{status}"

      Parsing.perform_async(genotype.id)
    end
  end
end
