#!/usr/bin/env ruby
# Edits FonosApp.xcodeproj without opening Xcode.
#   scripts/xcodeproj-add.rb normalize
#   scripts/xcodeproj-add.rb package <relative/package/path> <Product> <Target>
#   scripts/xcodeproj-add.rb file <path/to/File.swift> <Target>
# Run from the repository root. Needs: gem install --user-install xcodeproj
require "xcodeproj"

PROJECT = "FonosApp.xcodeproj"
project = Xcodeproj::Project.open(PROJECT)
command = ARGV.shift

def target_named(project, name)
  project.targets.find { |t| t.name == name } or abort "no target #{name}"
end

case command
when "normalize"
  # Saving re-serialises the file in xcodeproj's canonical order. Done once,
  # alone, so later edits produce small diffs.
when "package"
  path, product, target_name = ARGV
  target = target_named(project, target_name)
  ref = project.root_object.package_references.find do |r|
    r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) && r.relative_path == path
  end
  unless ref
    ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    ref.relative_path = path
    project.root_object.package_references << ref
  end
  unless target.package_product_dependencies.any? { |d| d.product_name == product }
    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.product_name = product
    dep.package = ref
    target.package_product_dependencies << dep
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dep
    target.frameworks_build_phase.files << build_file
  end
when "file"
  path, target_name = ARGV
  abort "missing #{path}" unless File.exist?(path)
  target = target_named(project, target_name)
  group = project.main_group
  File.dirname(path).split("/").each do |component|
    group = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && (c.path == component || c.name == component) } ||
            group.new_group(component, component)
  end
  name = File.basename(path)
  ref = group.files.find { |f| f.path == name } || group.new_reference(name)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
else
  abort File.read(__FILE__).lines[1..4].join
end

project.save
puts "#{command} #{ARGV.join(' ')}: saved #{PROJECT}"
