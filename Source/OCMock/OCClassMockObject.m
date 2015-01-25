/*
 *  Copyright (c) 2005-2014 Erik Doernenburg and contributors
 *
 *  Licensed under the Apache License, Version 2.0 (the "License"); you may
 *  not use these files except in compliance with the License. You may obtain
 *  a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 *  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  License for the specific language governing permissions and limitations
 *  under the License.
 */

#import <objc/runtime.h>
#import "OCClassMockObject.h"
#import "NSObject+OCMAdditions.h"
#import "OCMFunctions.h"
#import "OCMInvocationStub.h"

@interface OCClassMockObject ()
@property (retain, nonatomic) NSMutableArray *dependantMocks;
@property (retain, nonatomic) NSMutableArray *personalStubs;
@property (retain, nonatomic) OCClassMockObject *providerMock;
@end

@implementation OCClassMockObject

#pragma mark  Initialisers, description, accessors, etc.

- (id)initWithClass:(Class)aClass
{
    [super init];
    mockedClass = aClass;
    [self prepareClassForClassMethodMocking];
    _dependantMocks = [[NSMutableArray array] retain];
    [_dependantMocks addObject:[NSValue valueWithNonretainedObject:self]];
    _personalStubs = [[NSMutableArray array] retain];
    return self;
}

- (void)dealloc
{
    NSAssert(_dependantMocks.count == 0 || (_dependantMocks.count == 1 && [_dependantMocks containsObject:[NSValue valueWithNonretainedObject:self]]), @"");
    [_dependantMocks release];
    [_personalStubs release];
    [_providerMock removeDependantMock:self];
    [_providerMock release];
    [self stopMocking];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"OCMockObject(%@)", NSStringFromClass(mockedClass)];
}

- (Class)mockedClass
{
    return mockedClass;
}

#pragma mark  Extending/overriding superclass behaviour

- (void)stopMocking
{
    [self.dependantMocks removeObject:[NSValue valueWithNonretainedObject:self]];
    if ([self _canRestoreMetaClass]) {
        [self restoreMetaClass];
    } else {
        if (self.providerMock) {
            [OCClassMockObject _removeStubs:self.stubs fromMockObject:self.providerMock];
        } else {
            [OCClassMockObject _removeStubs:self.personalStubs fromMockObject:self];
        }
    }
    [super stopMocking];
}

- (void)restoreMetaClass
{
    OCMSetAssociatedMockForClass(nil, mockedClass);
    OCMSetIsa(mockedClass, originalMetaClass);
    originalMetaClass = nil;
}

- (void)addStub:(OCMInvocationStub *)aStub
{
    [super addStub:aStub];
    if ([aStub recordedAsClassMethod]) {
        if (self.providerMock) {
            [self.providerMock addDependantStub:aStub];
        } else {
            [self setupForwarderForClassMethodSelector:[[aStub recordedInvocation] selector]];
            [self.personalStubs addObject:aStub];
        }
    }
}

- (void)addDependantStub:(OCMInvocationStub *)stub {
    [super addStub:stub];
    [self setupForwarderForClassMethodSelector:[[stub recordedInvocation] selector]];
}


#pragma mark Dependant Mocks

- (void)addDependantMock:(OCClassMockObject *)dependantMock
{
    [self.dependantMocks addObject:[NSValue valueWithNonretainedObject:dependantMock]];
}

- (void)removeDependantMock:(OCClassMockObject *)dependantMock
{
    [self.dependantMocks removeObject:[NSValue valueWithNonretainedObject:dependantMock]];
    // If there are no other dependant mocks, we should restore the meta
    if ([self _canRestoreMetaClass])
    {
        [self restoreMetaClass];
    }
}

#pragma mark  Class method mocking

- (void)prepareClassForClassMethodMocking
{
    /* haven't figured out how to work around runtime dependencies on NSString, so exclude it for now */
    /* also weird: [[NSString class] isKindOfClass:[NSString class]] is false, hence the additional clause */
    if([[mockedClass class] isKindOfClass:[NSString class]] || (mockedClass == [NSString class]))
        return;

    /* if there is another mock for this exact class, stop it */
    OCClassMockObject *otherMock = OCMGetAssociatedMockForClass(mockedClass, NO);
    if (otherMock) {
        [otherMock addDependantMock:self];
        self.providerMock = otherMock;
        return;
    }

    OCMSetAssociatedMockForClass(self, mockedClass);

    /* dynamically create a subclass and use its meta class as the meta class for the mocked class */
    Class subclass = OCMCreateSubclass(mockedClass, mockedClass);
    originalMetaClass = object_getClass(mockedClass);
    id newMetaClass = object_getClass(subclass);
    OCMSetIsa(mockedClass, OCMGetIsa(subclass));

    /* point forwardInvocation: of the object to the implementation in the mock */
    Method myForwardMethod = class_getInstanceMethod([self mockObjectClass], @selector(forwardInvocationForClassObject:));
    IMP myForwardIMP = method_getImplementation(myForwardMethod);
    class_addMethod(newMetaClass, @selector(forwardInvocation:), myForwardIMP, method_getTypeEncoding(myForwardMethod));

    /* create a dummy initialize method */
    Method myDummyInitializeMethod = class_getInstanceMethod([self mockObjectClass], @selector(initializeForClassObject));
    const char *initializeTypes = method_getTypeEncoding(myDummyInitializeMethod);
    IMP myDummyInitializeIMP = method_getImplementation(myDummyInitializeMethod);
    class_addMethod(newMetaClass, @selector(initialize), myDummyInitializeIMP, initializeTypes);

    /* adding forwarder for most class methods (instance methods on meta class) to allow for verify after run */
    NSArray *methodBlackList = @[@"class", @"forwardingTargetForSelector:", @"methodSignatureForSelector:", @"forwardInvocation:", @"isBlock",
            @"instanceMethodForwarderForSelector:", @"instanceMethodSignatureForSelector:"];
    [NSObject enumerateMethodsInClass:originalMetaClass usingBlock:^(Class cls, SEL sel) {
        // If the method is on NSObject or NSObject's metaclass, we don't want to forward the metohd.
        if((cls == object_getClass([NSObject class])) || (cls == [NSObject class]) || (cls == object_getClass(cls)))
            return;
        NSString *className = NSStringFromClass(cls);
        NSString *selName = NSStringFromSelector(sel);
        if(([className hasPrefix:@"NS"] || [className hasPrefix:@"UI"]) &&
           ([selName hasPrefix:@"_"] || [selName hasSuffix:@"_"]))
            return;
        if([methodBlackList containsObject:selName])
            return;
        @try
        {
            [self setupForwarderForClassMethodSelector:sel];
        }
        @catch(NSException *e)
        {
            // ignore for now
        }
    }];
}

- (void)setupForwarderForClassMethodSelector:(SEL)selector
{
    SEL aliasSelector = OCMAliasForOriginalSelector(selector);
    if(class_getClassMethod(mockedClass, aliasSelector) != NULL)
        return;

    Method originalMethod = class_getClassMethod(mockedClass, selector);
    IMP originalIMP = method_getImplementation(originalMethod);
    const char *types = method_getTypeEncoding(originalMethod);

    Class metaClass = object_getClass(mockedClass);
    IMP forwarderIMP = [originalMetaClass instanceMethodForwarderForSelector:selector];
    class_replaceMethod(metaClass, selector, forwarderIMP, types);
    class_addMethod(metaClass, aliasSelector, originalIMP, types);
}


- (void)forwardInvocationForClassObject:(NSInvocation *)anInvocation
{
	// in here "self" is a reference to the real class, not the mock
	OCClassMockObject *mock = OCMGetAssociatedMockForClass((Class) self, YES);
    if(mock == nil)
    {
        [NSException raise:NSInternalInconsistencyException format:@"No mock for class %@", NSStringFromClass((Class)self)];
    }
	if([mock handleInvocation:anInvocation] == NO)
    {
        [anInvocation setSelector:OCMAliasForOriginalSelector([anInvocation selector])];
        [anInvocation invoke];
    }
}

- (void)initializeForClassObject
{
    // we really just want to have an implementation so that the superclass's is not called
}


#pragma mark  Proxy API

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
    return [mockedClass instanceMethodSignatureForSelector:aSelector];
}

- (Class)mockObjectClass
{
    return [super class];
}

- (Class)class
{
    return mockedClass;
}

- (BOOL)respondsToSelector:(SEL)selector
{
    return [mockedClass instancesRespondToSelector:selector];
}

- (BOOL)isKindOfClass:(Class)aClass
{
    return [mockedClass isSubclassOfClass:aClass];
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol
{
    return class_conformsToProtocol(mockedClass, aProtocol);
}

#pragma mark Helper methods

+ (void)_removeStubs:(NSArray *)stubs fromMockObject:(OCMockObject *)mockObject {
    for (OCMInvocationStub *stub in stubs) {
        [mockObject removeStub:stub];
    }
}

- (BOOL)_canRestoreMetaClass {
    return originalMetaClass && self.dependantMocks.count == 0;
}

@end


#pragma mark  -


/**
 taken from:
 `class-dump -f isNS /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator7.0.sdk/System/Library/Frameworks/CoreFoundation.framework`
 
 @interface NSObject (__NSIsKinds)
 - (_Bool)isNSValue__;
 - (_Bool)isNSTimeZone__;
 - (_Bool)isNSString__;
 - (_Bool)isNSSet__;
 - (_Bool)isNSOrderedSet__;
 - (_Bool)isNSNumber__;
 - (_Bool)isNSDictionary__;
 - (_Bool)isNSDate__;
 - (_Bool)isNSData__;
 - (_Bool)isNSArray__;
 */

@implementation OCClassMockObject(NSIsKindsImplementation)

- (BOOL)isNSValue__
{
    return [mockedClass isKindOfClass:[NSValue class]];
}

- (BOOL)isNSTimeZone__
{
    return [mockedClass isKindOfClass:[NSTimeZone class]];
}

- (BOOL)isNSSet__
{
    return [mockedClass isKindOfClass:[NSSet class]];
}

- (BOOL)isNSOrderedSet__
{
    return [mockedClass isKindOfClass:[NSOrderedSet class]];
}

- (BOOL)isNSNumber__
{
    return [mockedClass isKindOfClass:[NSNumber class]];
}

- (BOOL)isNSDate__
{
    return [mockedClass isKindOfClass:[NSDate class]];
}

- (BOOL)isNSString__
{
    return [mockedClass isKindOfClass:[NSString class]];
}

- (BOOL)isNSDictionary__
{
    return [mockedClass isKindOfClass:[NSDictionary class]];
}

- (BOOL)isNSData__
{
    return [mockedClass isKindOfClass:[NSData class]];
}

- (BOOL)isNSArray__
{
    return [mockedClass isKindOfClass:[NSArray class]];
}

@end
