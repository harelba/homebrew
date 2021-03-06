require "formula"
require "keg"
require "tab"
require "tap_migrations"

class Migrator
  class MigratorNoOldnameError < RuntimeError
    def initialize(formula)
      super "#{formula.name} doesn't replace any formula."
    end
  end

  class MigratorNoOldpathError < RuntimeError
    def initialize(formula)
      super "#{HOMEBREW_CELLAR/formula.oldname} doesn't exist."
    end
  end

  class MigratorDifferentTapsError < RuntimeError
    def initialize(formula, tap)
      if tap.nil?
        super <<-EOS.undent
        #{formula.name} from #{formula.tap} is given, but old name #{formula.oldname} wasn't installed from taps or core formulae

        You can try `brew migrate --force #{formula.oldname}`.
        EOS
      else
        user, repo = tap.split("/")
        repo.sub!("homebrew-", "")
        name = "fully-qualified #{user}/#{repo}/#{formula.oldname}"
        name = formula.oldname if tap == "Homebrew/homebrew"
        super <<-EOS.undent
        #{formula.name} from #{formula.tap} is given, but old name #{formula.oldname} was installed from #{tap}

        Please try to use #{name} to refer the formula
        EOS
      end
    end
  end

  attr_reader :formula
  attr_reader :oldname, :oldpath, :old_pin_record, :old_opt_record
  attr_reader :old_linked_keg_record, :oldkeg, :old_tabs, :old_tap
  attr_reader :newname, :newpath, :new_pin_record
  attr_reader :old_pin_link_record

  def initialize(formula)
    @oldname = formula.oldname
    @newname = formula.name
    raise MigratorNoOldnameError.new(formula) unless oldname

    @formula = formula
    @oldpath = HOMEBREW_CELLAR/formula.oldname
    raise MigratorNoOldpathError.new(formula) unless oldpath.exist?

    @old_tabs = oldpath.subdirs.each.map { |d| Tab.for_keg(Keg.new(d)) }
    @old_tap = old_tabs.first.tap
    raise MigratorDifferentTapsError.new(formula, old_tap) unless from_same_taps?

    @newpath = HOMEBREW_CELLAR/formula.name

    if @oldkeg = get_linked_oldkeg
      @old_linked_keg_record = oldkeg.linked_keg_record if oldkeg.linked?
      @old_opt_record = oldkeg.opt_record if oldkeg.optlinked?
    end

    @old_pin_record = HOMEBREW_LIBRARY/"PinnedKegs"/oldname
    @new_pin_record = HOMEBREW_LIBRARY/"PinnedKegs"/newname
    @pinned = old_pin_record.symlink?
    @old_pin_link_record = old_pin_record.readlink if @pinned
  end

  # Fix INSTALL_RECEIPTS for tap-migrated formula.
  def fix_tabs
    old_tabs.each do |tab|
      tab.source["tap"] = formula.tap
      tab.write
    end
  end

  def from_same_taps?
    if old_tap == nil && formula.core_formula? && ARGV.force?
      true
    elsif formula.tap == old_tap
      true
    # Homebrew didn't use to update tabs while performing tap-migrations,
    # so there can be INSTALL_RECEIPT's containing wrong information about
    # tap (tap is Homebrew/homebrew if installed formula migrates to a tap), so
    # we check if there is an entry about oldname migrated to tap and if
    # newname's tap is the same as tap to which oldname migrated, then we
    # can perform migrations and the taps for oldname and newname are the same.
    elsif TAP_MIGRATIONS && (rec = TAP_MIGRATIONS[formula.oldname]) \
          && rec == formula.tap.sub("homebrew-", "")
      fix_tabs
      true
    elsif formula.tap
      false
    end
  end

  def get_linked_oldkeg
    kegs = oldpath.subdirs.map { |d| Keg.new(d) }
    kegs.detect(&:linked?) || kegs.detect(&:optlinked?)
  end

  def pinned?
    @pinned
  end

  def oldkeg_linked?
    !!oldkeg
  end

  def migrate
    if newpath.exist?
      onoe "#{newpath} already exists; remove it manually and run brew migrate #{oldname}."
      return
    end

    begin
      oh1 "Migrating #{Tty.green}#{oldname}#{Tty.white} to #{Tty.green}#{newname}#{Tty.reset}"
      unlink_oldname
      move_to_new_directory
      repin
      link_newname
      link_oldname_opt
      link_oldname_cellar
      update_tabs
    rescue Interrupt
      ignore_interrupts { backup_oldname }
    rescue Exception => e
      onoe "error occured while migrating."
      puts e if ARGV.debug?
      puts "Backuping..."
      ignore_interrupts { backup_oldname }
    end
  end

  # move everything from Cellar/oldname to Cellar/newname
  def move_to_new_directory
    puts "Moving to: #{newpath}"
    FileUtils.mv(oldpath, newpath)
  end

  def repin
    if pinned?
      # old_pin_record is a relative symlink and when we try to to read it
      # from <dir> we actually try to find file
      # <dir>/../<...>/../Cellar/name/version.
      # To repin formula we need to update the link thus that it points to
      # the right directory.
      # NOTE: old_pin_record.realpath.sub(oldname, newname) is unacceptable
      # here, because it resolves every symlink for old_pin_record and then
      # substitutes oldname with newname. It breaks things like
      # Pathname#make_relative_symlink, where Pathname#relative_path_from
      # is used to find relative path from source to destination parent and
      # it assumes no symlinks.
      src_oldname = old_pin_record.dirname.join(old_pin_link_record).expand_path
      new_pin_record.make_relative_symlink(src_oldname.sub(oldname, newname))
      old_pin_record.delete
    end
  end

  def unlink_oldname
    oh1 "Unlinking #{Tty.green}#{oldname}#{Tty.reset}"
    oldpath.subdirs.each do |d|
      keg = Keg.new(d)
      keg.unlink
    end
  end

  def link_newname
    oh1 "Linking #{Tty.green}#{newname}#{Tty.reset}"
    keg = Keg.new(formula.installed_prefix)

    if formula.keg_only?
      begin
        keg.optlink
      rescue Keg::LinkError => e
        onoe "Failed to create #{formula.opt_prefix}"
        puts e
        raise
      end
      return
    end

    keg.remove_linked_keg_record if keg.linked?

    begin
      keg.link
    rescue Keg::ConflictError => e
      onoe "Error while executing `brew link` step on #{newname}"
      puts e
      puts
      puts "Possible conflicting files are:"
      mode = OpenStruct.new(:dry_run => true, :overwrite => true)
      keg.link(mode)
      raise
    rescue Keg::LinkError => e
      onoe "Error while linking"
      puts e
      puts
      puts "You can try again using:"
      puts "  brew link #{formula.name}"
    rescue Exception => e
      onoe "An unexpected error occurred during linking"
      puts e
      puts e.backtrace
      ignore_interrupts { keg.unlink }
      raise e
    end
  end

  # Link keg to opt if it was linked before migrating.
  def link_oldname_opt
    if old_opt_record
      old_opt_record.delete if old_opt_record.symlink? || old_opt_record.exist?
      old_opt_record.make_relative_symlink(formula.installed_prefix)
    end
  end

  # After migtaion every INSTALL_RECEIPT.json has wrong path to the formula
  # so we must update INSTALL_RECEIPTs
  def update_tabs
    new_tabs = newpath.subdirs.map { |d| Tab.for_keg(Keg.new(d)) }
    new_tabs.each do |tab|
      tab.source["path"] = formula.path.to_s if tab.source["path"]
      tab.write
    end
  end

  # Remove opt/oldname link if it belongs to newname.
  def unlink_oldname_opt
    return unless old_opt_record
    if old_opt_record.symlink? && formula.installed_prefix.exist? \
              && formula.installed_prefix.realpath == old_opt_record.realpath
      old_opt_record.unlink
      old_opt_record.parent.rmdir_if_possible
    end
  end

  # Remove oldpath if it exists
  def link_oldname_cellar
    oldpath.delete if oldpath.symlink? || oldpath.exist?
    oldpath.make_relative_symlink(formula.rack)
  end

  # Remove Cellar/oldname link if it belongs to newname.
  def unlink_oldname_cellar
    if (oldpath.symlink? && !oldpath.exist?) || (oldpath.symlink? \
          && formula.rack.exist? && formula.rack.realpath == oldpath.realpath)
      oldpath.unlink
    end
  end

  # Backup everything if errors occured while migrating.
  def backup_oldname
    unlink_oldname_opt
    unlink_oldname_cellar
    backup_oldname_cellar
    backup_old_tabs

    if pinned? && !old_pin_record.symlink?
      src_oldname = old_pin_record.dirname.join(old_pin_link_record).expand_path
      old_pin_record.make_relative_symlink(src_oldname)
      new_pin_record.delete
    end

    if newpath.exist?
      newpath.subdirs.each do |d|
        newname_keg = Keg.new(d)
        newname_keg.unlink
        newname_keg.uninstall
      end
    end

    if oldkeg_linked?
      begin
        # The keg used to be linked  and when we backup everything we restore
        # Cellar/oldname, the target also gets restored, so we are able to
        # create a keg using its old path
        keg = Keg.new(Pathname.new(oldkeg.to_s))
        keg.link
      rescue Keg::LinkError
        keg.unlink
        raise
      rescue Keg::AlreadyLinkedError
        keg.unlink
        retry
      end
    end
  end

  def backup_oldname_cellar
    unless oldpath.exist?
      FileUtils.mv(newpath, oldpath)
    end
  end

  def backup_old_tabs
    old_tabs.each(&:write)
  end
end
