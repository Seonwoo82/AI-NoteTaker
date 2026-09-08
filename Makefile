SHELL := /bin/zsh

PROJECT := NoteTaker.xcodeproj
SCHEME := NoteTaker
IOS_PROJECT := iOS/NoteTakerIOS.xcodeproj
IOS_SCHEME := NoteTakerIOS
IOS_DESTINATION ?= generic/platform=iOS Simulator
IOS_TEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
JOBS ?= 2
DERIVED_DATA := build/DerivedData
APP := $(abspath $(DERIVED_DATA)/Build/Products/Debug/AI-NoteTaker.app)
DESTINATION := platform=macOS,arch=arm64
BUNDLE_ID := com.seonwoo.notetaker
MODE ?= micOnly
SECONDS ?= 10
CLOCK ?= microphone
ifeq ($(origin OUTPUT), undefined)
OUTPUT := $(CURDIR)/build/smoke-$(MODE).m4a
endif

ifneq ($(filter smoke,$(MAKECMDGOALS)),)
ifneq ($(MODE),micOnly)
ifneq ($(MODE),systemOnly)
ifneq ($(MODE),micAndSystem)
$(error Unsupported smoke MODE: $(MODE); expected micOnly, systemOnly, or micAndSystem)
endif
endif
endif
ifneq ($(CLOCK),microphone)
ifneq ($(CLOCK),output)
$(error Unsupported smoke CLOCK: $(CLOCK); expected microphone or output)
endif
endif
endif

.PHONY: gen build run logs test uitest test-audio smoke reset-tcc sign-check clean

gen:
	xcodegen --use-cache
	xcodegen --spec iOS/project.yml --project iOS --use-cache

.PHONY: build-ios test-ios uitest-ios

build-ios:
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) -configuration Debug -destination '$(IOS_DESTINATION)' -derivedDataPath build/IOSDerivedData -jobs $(JOBS) build

test-ios:
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) -configuration Debug -destination '$(IOS_TEST_DESTINATION)' -derivedDataPath build/IOSDerivedData -jobs $(JOBS) -only-testing:NoteTakerIOSTests test

uitest-ios:
	xcodebuild -project $(IOS_PROJECT) -scheme $(IOS_SCHEME) -configuration Debug -destination '$(IOS_TEST_DESTINATION)' -derivedDataPath build/IOSDerivedData -jobs $(JOBS) -only-testing:NoteTakerIOSUITests test

build:
	xcodebuild -jobs $(JOBS) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

run: build
	-pkill -x AI-NoteTaker
	open -n "$(APP)"

logs:
	log stream --predicate 'subsystem == "$(BUNDLE_ID)"'

test:
	xcodebuild -jobs $(JOBS) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) -only-testing:NoteTakerTests test

uitest:
	xcodebuild -jobs $(JOBS) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA) -only-testing:NoteTakerUITests test

test-audio:
	swift test --package-path Packages/AudioPipeline

smoke: export MODE := $(value MODE)
smoke: export SECONDS := $(value SECONDS)
smoke: export OUTPUT := $(value OUTPUT)
smoke: export CLOCK := $(value CLOCK)
smoke: build
	scripts/smoke-record.sh "$(APP)"

reset-tcc:
	tccutil reset All $(BUNDLE_ID)

sign-check: build
	codesign -dvv "$(APP)"
	codesign -d --entitlements - "$(APP)"

clean:
	rm -rf build
