# Copyright 2012 Square Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require 'spec_helper'

describe Occurrence do
  context "[database rules]" do
    it "should set number sequentially for a given bug" do
      bug1 = FactoryGirl.create(:bug)
      bug2 = FactoryGirl.create(:bug)

      occurrence1_1 = FactoryGirl.create(:rails_occurrence, bug: bug1)
      occurrence1_2 = FactoryGirl.create(:rails_occurrence, bug: bug1)
      occurrence2_1 = FactoryGirl.create(:rails_occurrence, bug: bug2)
      occurrence2_2 = FactoryGirl.create(:rails_occurrence, bug: bug2)

      occurrence1_1.number.should eql(1)
      occurrence1_2.number.should eql(2)
      occurrence2_1.number.should eql(1)
      occurrence2_2.number.should eql(2)
    end

    it "should not reuse deleted numbers" do
      #bug = FactoryGirl.create(:bug)
      #FactoryGirl.create :rails_occurrence, bug: bug
      #FactoryGirl.create(:rails_occurrence, bug: bug).destroy
      #FactoryGirl.create(:rails_occurrence, bug: bug).number.should eql(3)
      #TODO get this part of the spec to work (for URL-resource identity integrity)

      bug = FactoryGirl.create(:bug)
      FactoryGirl.create :rails_occurrence, bug: bug
      c = FactoryGirl.create(:rails_occurrence, bug: bug)
      FactoryGirl.create :rails_occurrence, bug: bug
      c.destroy
      FactoryGirl.create(:rails_occurrence, bug: bug).number.should eql(4)
    end

    it "should set the parent's first occurrence if necessary" do
      o = FactoryGirl.create(:rails_occurrence)
      o.bug.first_occurrence.should eql(o.occurred_at)
    end
  end

  context "[hooks]" do
    it "should symbolicate after being created" do
      symbols = Squash::Symbolicator::Symbols.new
      symbols.add 1, 10, 'foo.rb', 5, 'bar'
      symb = FactoryGirl.create(:symbolication, symbols: symbols)
      FactoryGirl.create(:rails_occurrence,
                         symbolication: symb,
                         backtraces:    [['1', true, [['_RETURN_ADDRESS_', 5]]]]).
          should be_symbolicated
    end

    it "should send an email if the notification threshold has been tripped" do
      if RSpec.configuration.use_transactional_fixtures
        pending "This is done in an after_commit hook, and it can't be tested with transactional fixtures (which are always rolled back)"
      end

      occurrence = FactoryGirl.create(:rails_occurrence)
      nt         = FactoryGirl.create(:notification_threshold, bug: occurrence.bug, period: 1.minute, threshold: 3)
      ActionMailer::Base.deliveries.clear

      FactoryGirl.create :rails_occurrence, bug: occurrence.bug
      ActionMailer::Base.deliveries.should be_empty

      FactoryGirl.create :rails_occurrence, bug: occurrence.bug
      ActionMailer::Base.deliveries.size.should eql(1)
      ActionMailer::Base.deliveries.first.to.should eql([nt.user.email])
    end

    it "should update last_tripped_at" do
      if RSpec.configuration.use_transactional_fixtures
        pending "This is done in an after_commit hook, and it can't be tested with transactional fixtures (which are always rolled back)"
      end

      occurrence = FactoryGirl.create(:rails_occurrence)
      nt         = FactoryGirl.create(:notification_threshold, bug: occurrence.bug, period: 1.minute, threshold: 3)

      FactoryGirl.create :rails_occurrence, bug: occurrence.bug
      nt.reload.last_tripped_at.should be_nil

      FactoryGirl.create :rails_occurrence, bug: occurrence.bug
      nt.reload.last_tripped_at.should be_within(1).of(Time.now)
    end

    context "[PagerDuty integration]" do
      before :each do
        FakeWeb.register_uri :post,
                             Squash::Configuration.pagerduty.api_url,
                             response: File.read(Rails.root.join('spec', 'fixtures', 'pagerduty_response.json'))

        @project = FactoryGirl.create(:project, pagerduty_service_key: 'abc123', critical_threshold: 2, pagerduty_enabled: true)
        @environment = FactoryGirl.create(:environment, project: @project, notifies_pagerduty: true)
        @bug = FactoryGirl.create(:bug, environment: @environment)
      end

      it "should not send an incident to PagerDuty until the critical threshold is breached" do
        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 2, bug: @bug
      end

      it "should send an incident to PagerDuty once the critical threshold is breached" do
        FactoryGirl.create_list :rails_occurrence, 2, bug: @bug
        Service::PagerDuty.any_instance.should_receive(:trigger).once.with(
            /#{Regexp.escape @bug.class_name} in #{Regexp.escape File.basename(@bug.file)}:#{@bug.line}/,
            @bug.pagerduty_incident_key,
            an_instance_of(Hash)
        )
        FactoryGirl.create :rails_occurrence, bug: @bug
      end

      it "should not send an incident if the project does not have a session key configured" do
        @project.update_attribute :pagerduty_service_key, nil

        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 3, bug: @bug
      end

      it "should not send an incident if incident reporting is disabled" do
        @project.update_attribute :pagerduty_enabled, false

        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 3, bug: @bug
      end

      it "should not send an incident if the environment has incident reporting disabled" do
        @environment.update_attribute :notifies_pagerduty, nil

        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 3, bug: @bug
      end

      it "should not send an incident if the bug is assigned" do
        @bug.update_attribute :assigned_user, FactoryGirl.create(:membership, project: @project).user

        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 3, bug: @bug
      end

      it "should not send an incident if the bug is irrelevant" do
        @bug.update_attribute :irrelevant, true

        PagerDutyNotifier.any_instance.should_not_receive :trigger
        FactoryGirl.create_list :rails_occurrence, 3, bug: @bug
      end
    end unless Squash::Configuration.pagerduty.disabled?
  end

  describe "#faulted_backtrace" do
    it "should return the at-fault backtrace" do
      bt1 = [['foo.rb', 123, 'bar']]
      bt2 = [['bar.rb', 321, 'foo']]
      FactoryGirl.build(:occurrence, backtraces: [["1", false, bt1], ['2', true, bt2]]).faulted_backtrace.should eql(bt2)
    end

    it "should return an empty array if there is no at-fault backtrace" do
      bt1 = [['foo.rb', 123, 'bar']]
      bt2 = [['bar.rb', 321, 'foo']]
      FactoryGirl.build(:occurrence, backtraces: [["1", false, bt1], ['2', false, bt2]]).faulted_backtrace.should eql([])
    end
  end

  describe "#truncate!" do
    it "should remove metadata" do
      o   = FactoryGirl.create(:rails_occurrence)
      old = o.attributes

      o.truncate!
      o.should be_truncated

      o.metadata.should be_nil
      o.client.should eql(old['client'])
      o.occurred_at.should eql(old['occurred_at'])
      o.bug_id.should eql(old['bug_id'])
      o.number.should eql(old['number'])
    end
  end

  describe ".truncate!" do
    it "should truncate a group of exceptions" do
      os      = FactoryGirl.create_list :rails_occurrence, 4
      another = FactoryGirl.create :rails_occurrence
      Occurrence.truncate! Occurrence.where(id: os.map(&:id))
      os.map(&:reload).all?(&:truncated?).should be_true
      another.reload.should_not be_truncated
    end
  end

  describe "#redirect_to" do
    it "should truncate the occurrence and set the redirect target" do
      o1 = FactoryGirl.create(:rails_occurrence)
      o2 = FactoryGirl.create(:rails_occurrence, bug: o1.bug)
      o1.redirect_to! o2
      o1.redirect_target.should eql(o2)
      o1.should be_truncated
    end
  end

  describe "#symbolicate!" do
    before(:each) do
      @occurrence = FactoryGirl.create(:rails_occurrence)
      # there's a uniqueness constraint on repo URLs, but we need a real repo with real commits
      @occurrence.bug.environment.project.instance_variable_set :@repo, Project.new { |pp| pp.repository_url = 'git://github.com/RISCfuture/better_caller.git' }.repo
      @occurrence.bug.update_attribute :deploy, FactoryGirl.create(:deploy, environment: @occurrence.bug.environment)
    end

    it "should do nothing if there is no symbolication" do
      @occurrence.symbolication_id = nil
      -> { @occurrence.symbolicate! }.should_not change(@occurrence, :backtraces)
    end

    it "should do nothing if the occurrence is truncated" do
      @occurrence.truncate!
      -> { @occurrence.symbolicate! }.should_not change(@occurrence, :metadata)
    end

    it "should do nothing if the occurrence is already symbolicated" do
      @occurrence.backtraces = [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_RETURN_ADDRESS_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]
      -> { @occurrence.symbolicate! }.should_not change(@occurrence, :backtraces)
    end

    it "should symbolicate the occurrence" do
      symbols = Squash::Symbolicator::Symbols.new
      symbols.add 1, 10, 'foo.rb', 15, 'bar'
      symbols.add 11, 20, 'foo2.rb', 5, 'bar2'
      symb = FactoryGirl.create(:symbolication, symbols: symbols)

      @occurrence.symbolication = symb
      @occurrence.backtraces    = [["Thread 0", true, [
          ['_RETURN_ADDRESS_', 1],
          ['_RETURN_ADDRESS_', 2],
          ['_RETURN_ADDRESS_', 12],
          ['_RETURN_ADDRESS_', 10, 'timeout']
      ]]]
      @occurrence.symbolicate!

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['foo.rb', 15, 'bar'],
          ['foo.rb', 15, 'bar'],
          ['foo2.rb', 5, 'bar2'],
          ['_RETURN_ADDRESS_', 10, 'timeout']
      ]]])
    end


    it "should use a custom symbolication" do
      symbols1 = Squash::Symbolicator::Symbols.new
      symbols1.add 1, 10, 'foo.rb', 15, 'bar'
      symbols1.add 11, 20, 'foo2.rb', 5, 'bar2'
      symbols2 = Squash::Symbolicator::Symbols.new
      symbols2.add 1, 10, 'foo3.rb', 15, 'bar3'
      symbols2.add 11, 20, 'foo4.rb', 5, 'bar4'

      symb1 = FactoryGirl.create(:symbolication, symbols: symbols1)
      symb2 = FactoryGirl.create(:symbolication, symbols: symbols2)

      @occurrence.symbolication = symb1
      @occurrence.backtraces    = [["Thread 0", true, [
          ['_RETURN_ADDRESS_', 1],
          ['_RETURN_ADDRESS_', 2],
          ['_RETURN_ADDRESS_', 12],
          ['_RETURN_ADDRESS_', 10, 'timeout']
      ]]]
      @occurrence.symbolicate! symb2

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['foo3.rb', 15, 'bar3'],
          ['foo3.rb', 15, 'bar3'],
          ['foo4.rb', 5, 'bar4'],
          ['_RETURN_ADDRESS_', 10, 'timeout']
      ]]])
    end
  end

  describe "#symbolicated?" do
    it "should return true if all lines are symbolicated" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_RETURN_ADDRESS_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should be_symbolicated
    end

    it "should return false if any line is unsymbolicated" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['_RETURN_ADDRESS_', 4632],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should_not be_symbolicated
    end
  end

  describe "#sourcemap!" do
    before(:each) do
      @occurrence = FactoryGirl.create(:rails_occurrence)
      # there's a uniqueness constraint on repo URLs, but we need a real repo with real commits
      @occurrence.bug.environment.project.instance_variable_set :@repo, Project.new { |pp| pp.repository_url = 'git://github.com/RISCfuture/better_caller.git' }.repo
      @occurrence.bug.update_attribute :deploy, FactoryGirl.create(:deploy, environment: @occurrence.bug.environment)
    end

    it "should do nothing if there is no source map" do
      -> { @occurrence.sourcemap! }.should_not change(@occurrence, :backtraces)
    end

    it "should do nothing if the occurrence is truncated" do
      @occurrence.truncate!
      -> { @occurrence.sourcemap! }.should_not change(@occurrence, :metadata)
    end

    it "should do nothing if the occurrence is already sourcemapped" do
      @occurrence.backtraces = [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_JAVA_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]
      -> { @occurrence.sourcemap! }.should_not change(@occurrence, :backtraces)
    end

    it "should sourcemap the occurrence" do
      map = Squash::Javascript::SourceMap.new
      map << Squash::Javascript::SourceMap::Mapping.new('http://test.host/example/asset.js', 3, 140, 'app/assets/javascripts/source.js', 25, 1, 'foobar')
      FactoryGirl.create :source_map, environment: @occurrence.bug.environment, revision: @occurrence.revision, map: map

      @occurrence.backtraces = [["Thread 0", true, [
          ['_JS_ASSET_', 'http://test.host/example/asset.js', 3, 140, 'foo', nil]
      ]]]
      @occurrence.sourcemap!

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['app/assets/javascripts/source.js', 25, 'foobar']
      ]]])
    end


    it "should use a custom sourcemap" do
      map1 = Squash::Javascript::SourceMap.new
      map1 << Squash::Javascript::SourceMap::Mapping.new('http://test.host/example/asset.js', 3, 140, 'app/assets/javascripts/source1.js', 1, 1, 'foobar1')
      map2 = Squash::Javascript::SourceMap.new
      map2 << Squash::Javascript::SourceMap::Mapping.new('http://test.host/example/asset.js', 3, 140, 'app/assets/javascripts/source2.js', 2, 2, 'foobar2')

      sm1 = FactoryGirl.create :source_map, environment: @occurrence.bug.environment, revision: @occurrence.revision, map: map1
      sm2 = FactoryGirl.create :source_map, map: map2

      @occurrence.backtraces = [["Thread 0", true, [
          ['_JS_ASSET_', 'http://test.host/example/asset.js', 3, 140, 'foo', nil]
      ]]]
      @occurrence.sourcemap! sm2

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['app/assets/javascripts/source2.js', 2, 'foobar2']
      ]]])
    end
  end

  describe "#sourcemapped?" do
    it "should return true if all lines are source-mapped" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_RETURN_ADDRESS_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should be_sourcemapped
    end

    it "should return false if any line is not source-mapped" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['_JS_ASSET_', 'http://test.host/my.js', 20, 5, 'myfunction', nil],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should_not be_sourcemapped
    end
  end

  describe "#deobfuscate!" do
    before(:each) do
      @occurrence = FactoryGirl.create(:rails_occurrence)
      # there's a uniqueness constraint on repo URLs, but we need a real repo with real commits
      @occurrence.bug.environment.project.instance_variable_set :@repo, Project.new { |pp| pp.repository_url = 'git://github.com/RISCfuture/better_caller.git' }.repo
      @occurrence.bug.update_attribute :deploy, FactoryGirl.create(:deploy, environment: @occurrence.bug.environment)
    end

    it "should do nothing if there is no obfuscation map" do
      -> { @occurrence.deobfuscate! }.should_not change(@occurrence, :backtraces)
    end

    it "should do nothing if the occurrence is truncated" do
      @occurrence.truncate!
      -> { @occurrence.deobfuscate! }.should_not change(@occurrence, :metadata)
    end

    it "should do nothing if the occurrence is already de-obfuscated" do
      @occurrence.backtraces = [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_JAVA_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]
      -> { @occurrence.deobfuscate! }.should_not change(@occurrence, :backtraces)
    end

    it "should deobfuscate the occurrence" do
      namespace = Squash::Java::Namespace.new
      namespace.add_package_alias 'com.foo', 'A'
      namespace.add_class_alias('com.foo.Bar', 'B').path = 'src/foo/Bar.java'
      namespace.add_method_alias 'com.foo.Bar', 'int baz(java.lang.String)', 'a'
      FactoryGirl.create :obfuscation_map, namespace: namespace, deploy: @occurrence.bug.deploy

      @occurrence.backtraces = [["Thread 0", true, [
          ['_JAVA_', 'B.java', 15, 'int a(java.lang.String)', 'com.A.B']
      ]]]
      @occurrence.deobfuscate!

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['src/foo/Bar.java', 15, 'int baz(java.lang.String)']
      ]]])
    end

    it "should leave un-obfuscated names intact" do
      namespace = Squash::Java::Namespace.new
      namespace.add_package_alias 'com.foo', 'A'
      namespace.add_class_alias('com.foo.Bar', 'B').path = 'src/foo/Bar.java'
      namespace.add_method_alias 'com.foo.Bar', 'int baz(java.lang.String)', 'a'
      FactoryGirl.create :obfuscation_map, namespace: namespace, deploy: @occurrence.bug.deploy

      @occurrence.backtraces = [["Thread 0", true, [
          ['_JAVA_', 'B.java', 15, 'int b(java.lang.String)', 'com.A.B'],
          ['_JAVA_', 'ActivityThread.java', 15, 'int a(java.lang.String)', 'com.squareup.ActivityThread']
      ]]]
      @occurrence.deobfuscate!

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['src/foo/Bar.java', 15, 'int b(java.lang.String)'],
          ['_JAVA_', 'ActivityThread.java', 15, 'int a(java.lang.String)', 'com.squareup.ActivityThread']
      ]]])
    end

    it "should use a custom obfuscation map" do
      namespace1 = Squash::Java::Namespace.new
      namespace1.add_package_alias 'com.foo', 'A'
      namespace1.add_class_alias('com.foo.BarOne', 'B').path = 'src/foo/BarOne.java'
      namespace1.add_method_alias 'com.foo.BarOne', 'int baz1(java.lang.String)', 'a'

      namespace2 = Squash::Java::Namespace.new
      namespace2.add_package_alias 'com.foo', 'A'
      namespace2.add_class_alias('com.foo.BarTwo', 'B').path = 'src/foo/BarTwo.java'
      namespace2.add_method_alias 'com.foo.BarTwo', 'int baz2(java.lang.String)', 'a'

      om1 = FactoryGirl.create(:obfuscation_map, namespace: namespace1, deploy: @occurrence.bug.deploy)
      om2 = FactoryGirl.create(:obfuscation_map, namespace: namespace2, deploy: @occurrence.bug.deploy)

      @occurrence.backtraces = [["Thread 0", true, [
          ['_JAVA_', 'B.java', 15, 'int a(java.lang.String)', 'com.A.B']
      ]]]
      @occurrence.deobfuscate! om2

      @occurrence.changes.should be_empty
      @occurrence.backtraces.should eql([["Thread 0", true, [
          ['src/foo/BarTwo.java', 15, 'int baz2(java.lang.String)']
      ]]])
    end
  end

  describe "#deobfuscated?" do
    it "should return true if all lines are deobfuscated" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 637, 'do_start'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['_JAVA_', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should be_deobfuscated
    end

    it "should return false if any line is deobfuscated" do
      FactoryGirl.build(:occurrence, backtraces: [["Thread 0", true, [
          ['/usr/bin/gist', 313, '<main>'],
          ['/usr/bin/gist', 171, 'execute'],
          ['/usr/bin/gist', 197, 'write'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 626, 'start'],
          ['_JAVA_', 'A.java', 15, 'b', 'A'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'connect'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 87, 'timeout'],
          ['/usr/lib/ruby/1.9.1/timeout.rb', 44, 'timeout'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'block in connect'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'open'],
          ['/usr/lib/ruby/1.9.1/net/http.rb', 644, 'initialize']
      ]]]).should_not be_deobfuscated
    end
  end

  describe "#recategorize!" do
    it "should re-assign the Occurrence to a different bug if necessary" do
      bug1 = FactoryGirl.create(:bug)
      bug2 = FactoryGirl.create(:bug, environment: bug1.environment)
      occ  = FactoryGirl.create(:rails_occurrence, bug: bug1)

      blamer = Blamer.new(occ)
      Blamer.stub!(:new).and_return(blamer)
      blamer.should_receive(:find_or_create_bug!).once.and_return(bug2)

      message     = occ.message
      revision    = occ.revision
      occurred_at = occ.occurred_at
      client      = occ.client
      occ.recategorize!

      bug2.occurrences.count.should eql(1)
      occ2 = bug2.occurrences.first
      occ.redirect_target.should eql(occ2)

      occ2.message.should eql(message)
      occ2.revision.should eql(revision)
      occ2.occurred_at.should eql(occurred_at)
      occ2.client.should eql(client)
    end

    it "should reopen the new bug if necessary" do
      bug1 = FactoryGirl.create(:bug)
      bug2 = FactoryGirl.create(:bug, environment: bug1.environment, fixed: true, fix_deployed: true)
      occ  = FactoryGirl.create(:rails_occurrence, bug: bug1)

      blamer = Blamer.new(occ)
      Blamer.stub!(:new).and_return(blamer)
      blamer.should_receive(:find_or_create_bug!).once.and_return(bug2)

      message     = occ.message
      revision    = occ.revision
      occurred_at = occ.occurred_at
      client      = occ.client
      occ.recategorize!

      bug2.occurrences.count.should eql(1)
      occ2 = bug2.occurrences.first
      occ.redirect_target.should eql(occ2)

      occ2.message.should eql(message)
      occ2.revision.should eql(revision)
      occ2.occurred_at.should eql(occurred_at)
      occ2.client.should eql(client)
    end
  end
end
