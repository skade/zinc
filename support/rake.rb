require 'digest'
require 'set'
require 'pry'

class String
  def in_build; Context.build_dir(self); end
  def in_intermediate; Context.intermediate_dir(self); end
  def in_root; Context.root_dir(self); end
  def in_source; Context.src_dir(self); end
  def in_platform; Context.platform_dir(self); end
  def as_rlib; Rlib.name(self); end
end

class Hash
  def resolve_deps!
    return unless self[:deps]
    self[:deps] = [self[:deps]].flatten

    self[:deps] = self[:deps].map do |d|
      if d.kind_of?(Symbol)
        raise RuntimeError.new("Missing rule #{d}") unless Context.rules[d]
        Context.rules[d][:produce]
      else
        d
      end
    end
    self
  end
end

module Context
  class << self
    attr_reader :app_name, :app
  end

  def self.src_dir(*args)
    File.join(root_dir, 'src', *args)
  end

  def self.build_dir(*args)
    File.join(root_dir, 'build', *args)
  end

  def self.intermediate_dir(*args)
    File.join(root_dir, 'build', 'intermediate', *args)
  end

  def self.platform_dir(*args)
    src_dir('hal', @current_platform.to_s, *args)
  end

  def self.prepare!(rsflags, ldflags, platforms, architectures, features)
    platform_file = File.join(build_dir, ".platform")

    current_platform_str = ENV['PLATFORM'] or raise ArgumentError.new("Undefined platform, available platforms: #{platforms.keys.join(', ')}")
    @current_platform = current_platform_str.to_sym
    previous_platform = File.exists?(platform_file) ?
      open(platform_file).read.to_sym : nil

    if previous_platform && (@current_platform != previous_platform)
      FileUtils.rm_rf(build_dir)
    end

    FileUtils.mkdir(build_dir) unless Dir.exists?(build_dir)
    FileUtils.mkdir(intermediate_dir) unless Dir.exists?(intermediate_dir)
    open(platform_file, 'w') { |f| f.write(@current_platform) }

    platform = platforms[@current_platform] or raise ArgumentError.new("Undefined platform #{@current_platform}, available platforms: #{platforms.keys.join(', ')}")
    arch = architectures[platform[:arch]] or raise ArgumentError.new("Undefined arch #{platform[:arch]} for platform #{@current_platform}")

    feature_flags = (features + (platform[:features] or [])).map do |c|
      "--cfg cfg_#{c}"
    end

    unless FORCE_NATIVE_BUILD
      rsflags.push(
        "--target #{arch[:target]}",
        "-Ctarget-cpu=#{arch[:cpu]}"
      )
    end
    rsflags.push(
      "--cfg #{platform[:config]}",
      "--cfg arch_#{platform[:arch]}",
      *feature_flags)
    ldflags.push("-L#{File.join(TOOLCHAIN_LIBS_PATH, arch[:arch])}")

    if ENV['DEBUG']
      rsflags.push('--opt-level 0')
    else
      rsflags.push('--opt-level 2')
    end

    ENV['RSFLAGS'] = rsflags.join(' ')
    ENV['LDFLAGS'] = ldflags.join(' ')

    unless FORCE_NATIVE_BUILD
      ENV['CFLAGS'] = ["-mthumb -mcpu=#{arch[:cpu]}"].join(' ')
    end

    @app_name = ENV['APP'] or ArgumentError.new("Undefined application")
    app_path = root_dir('apps', @app_name + '.rs') or ArgumentError.new("Application #{@app_name} not found in apps")

    @app = app_path
  end

  def self.root_dir(*args)
    File.join(File.dirname(File.dirname(__FILE__)), *args)
  end

  def self.track_application_name
    AppDepTask.define_task(build_dir('.app')) do |t|
      t.store_name
    end
  end

  def self.rules
    @rules ||= {}
  end
end

class AppDepTask < Rake::Task
  def needed?
    if File.exist?(name)
      build_app_name = open(name).read.strip
      if build_app_name != Context.app_name
        true
      else
        false
      end
    else
      true
    end
  end

  def store_name
    open(name, 'w') do |f|
      f.write(Context.app_name)
    end
  end

  def timestamp
    if File.exist?(name)
      File.mtime(name.to_s)
    else
      Rake::EARLY
    end
  end
end

module Rlib
  def self.name(src)
    get_cached(src)
  end

  private
  def self.get_cached(src)
    @cache ||= {}
    unless @cache[src]
      crate, version = crate_id(src)
      digest = Digest::SHA256.hexdigest(crate + '-' + version)[0...8]
      name = "lib#{crate}-#{digest}-#{version}.rlib"
      @cache[src] = name
    end

    @cache[src]
  end

  def self.crate_id(src)
    crate = File.basename(src, File.extname(src))
    version = '0.0'

    id_regex = /#!\[crate_id.*=.*"([a-zA-Z0-9_]+)(?:#([a-zA-Z0-9_.\-]+))?"\]/
    lines = open(src).read.split("\n")
    lines.each do |l|
      m = id_regex.match(l)
      if m
        crate = m[1]
        version = m[2] ? m[2] : '0.0'
        return [crate, version]
      end
    end
    return [crate, version]
  end
end

module Rust
  def self.collect_dep_srcs(src, root)
    dep_files = submodules(src, root)
    return Set.new if dep_files.empty?

    collected_deps = dep_files.dup

    dep_files.each do |f|
      collected_deps += collect_dep_srcs(f, src)
    end

    collected_deps
  end

  def self.submodules(src, root=nil)
    subs = Set.new
    unless File.exists?(src)
      raise RuntimeError.new("Cannot find #{src} included from #{root}")
    end
    lines = open(src).read.split("\n")
    mod_rx = /^\s*(?:#\[.+\]\s*)*(?:pub)?\s*mod\s+(\w+)\s*;/
    path_rx = /^\s*#\[path\s*=\s*"([^"]+)"\]/
    mod_path_rx = /^\s*#\[path\s*=\s*"([^"]+)"\]\s+(?:pub)?\s*mod\s+\w+\s*;/
    prev = ''
    lines.each do |l|
      mp = mod_path_rx.match(l)
      if mp
        subs << File.join(File.dirname(src), mp[1]) if mp
      else
        m = mod_rx.match(l)
        p = path_rx.match(prev)

        if m
          if p
            subs << File.join(File.dirname(src), p[1])
          else
            subs << mod_to_src(src, m[1])
          end
        end
      end
      prev = l
    end
    subs
  end

  def self.mod_to_src(src, mod)
    fn1 = File.join(File.dirname(src), mod + '.rs')
    return fn1 if File.exists?(fn1)
    fn2 = File.join(File.dirname(src), mod, 'mod.rs')
    return fn2 if File.exists?(fn2)
    raise ArgumentError.new("Cannot resolve mod #{mod} in scope of #{src}, tried #{fn1} and #{fn2}")
  end
end

def report_size(fn)
  Rake::Task.define_task :report_size => fn do |t|
    fn = t.prerequisites.first

    stats = `#{TOOLCHAIN}-size #{fn}`.split("\n").last.split("\t").map {|s|s.strip}
    align = stats[3].length
    puts "Statistics for #{File.basename(fn)}"
    puts "  .text: #{stats[0].rjust(align)} bytes"
    puts "  .data: #{stats[1].rjust(align)} bytes"
    puts "  .bss:  #{stats[2].rjust(align)} bytes"
    puts "         #{'='*(align+6)}"
    puts "  TOTAL: #{stats[3]} bytes (0x#{stats[4]})"
  end
end

def compile_rust(n, h)
  h.resolve_deps!
  Context.rules[n] = h

  outflags = h[:out_dir] ? "--out-dir #{Context.build_dir}" : "-o #{h[:produce]}"
  llvm_pass = h[:llvm_pass]
  lto = h[:lto]
  lto = true if lto == nil
  optimize = h[:optimize]
  crate_type = h[:crate_type] ? "--crate-type #{h[:crate_type]}" : ""
  ignore_warnings = h[:ignore_warnings] ? h[:ignore_warnings] : []
  ignore_warnings = ignore_warnings.map { |w| "-A #{w}" }.join(' ')

  declared_deps = h[:deps]
  rust_src = h[:source]
  deps = Rust.collect_dep_srcs(rust_src, '__ROOT__').to_a
  all_deps = [rust_src, declared_deps, deps].flatten.compact

  Rake::FileTask.define_task(h[:produce] => all_deps) do |t|
    do_lto = lto && t.name.end_with?('.o')
    emit = case File.extname(t.name)
      when '.o'
        '--emit obj'
      when '.ll'
        '--emit ir'
      when '.s'
        '--emit asm'
      else
        ''
    end

    codegen = llvm_pass ? "-C passes=#{llvm_pass}" : ''

    flags = ENV['RSFLAGS']
    if optimize
      flags.gsub!(/--opt-level \d/, "--opt-level #{optimize}")
    end

    sh "#{RUSTC} #{flags} " +
       "#{do_lto ? '-Z lto' : ''} #{crate_type} #{emit} -L #{Context.build_dir} #{codegen} " +
       "#{outflags} #{ignore_warnings} #{rust_src}"
  end
end

def link_binary(n, h)
  h.resolve_deps!
  script = h[:script]

  Rake::FileTask.define_task(h[:produce] => [h[:deps], script].flatten) do |t|
    t.prerequisites.delete(script)
    mapfn = Context.build_dir(File.basename(t.name, File.extname(t.name)) + '.map')

    sh "#{TOOLCHAIN}-ld -Map #{mapfn} -o #{t.name} -T #{script} " +
       "#{t.prerequisites.join(' ')} #{ENV['LDFLAGS']} --gc-sections -lgcc"

    # sh "#{TOOLCHAIN}-strip -N ISRVectors -N NVICVectors -N support.rs -N app.rs -N isr.rs #{t.name}"
  end
end

def compile_c(n, h)
  h.resolve_deps!
  Context.rules[n] = h

  Rake::FileTask.define_task(h[:produce] => [h[:source], h[:deps]].flatten.compact) do |t|
    sh "#{TOOLCHAIN}-gcc #{ENV['CFLAGS']} -o #{h[:produce]} -c #{h[:source]}"
  end
end

def listing(n, h)
  Rake::FileTask.define_task(h[:produce] => h[:source]) do |t|
    sh "#{TOOLCHAIN}-objdump -D #{t.prerequisites.first} > #{t.name}"
  end
end

def make_binary(n, h)
  Rake::FileTask.define_task(h[:produce] => h[:source]) do |t|
    sh "#{TOOLCHAIN}-objcopy #{t.prerequisites.first} #{t.name} -O binary"
  end
end

def provide_stdlibs
  liblibc_src = 'thirdparty/liblibc/lib.rs'.in_root
  libstd_src = 'thirdparty/libstd/lib.rs'.in_root

  directory 'thirdparty'.in_root

  Rake::FileTask.define_task 'thirdparty/rust' do |t|
    sh "git clone --single-branch --depth 1 https://github.com/mozilla/rust #{t.name} && " +
    "cd thirdparty/rust/src && patch -p1 -i ../../../support/rust.patch"
  end

  Rake::FileTask.define_task libstd_src => 'thirdparty/rust' do |t|
    sh "ln -s rust/src/libstd thirdparty/libstd"
  end.invoke

  Rake::FileTask.define_task liblibc_src => 'thirdparty/rust' do |t|
    sh "ln -s rust/src/liblibc thirdparty/liblibc"
  end.invoke

  Rake::FileTask.define_task 'librustrt.a'.in_build do |t|
    sh "#{TOOLCHAIN}-ar cr #{t.name}"
  end.invoke

  Rake::FileTask.define_task 'libbacktrace.a'.in_build do |t|
    sh "#{TOOLCHAIN}-ar cr #{t.name}"
  end.invoke
end