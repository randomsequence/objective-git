//
//  GTBranch.m
//  ObjectiveGitFramework
//
//  Created by Josh Abernathy on 3/3/11.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

#import "GTBranch.h"
#import "GTReference.h"
#import "GTEnumerator.h"
#import "GTRepository.h"
#import "GTCommit.h"
#import "NSError+Git.h"


@interface GTBranch ()
@property (nonatomic, strong) GTReference *reference;
@property (nonatomic, strong) GTRepository *repository;
@end

@implementation GTBranch

- (NSString *)description {
  return [NSString stringWithFormat:@"<%@: %p> name: %@, shortName: %@, sha: %@, remoteName: %@, repository: %@", NSStringFromClass([self class]), self, self.name, self.shortName, self.sha, self.remoteName, self.repository];
}

- (BOOL)isEqual:(GTBranch *)otherBranch {
	if (otherBranch == self) return YES;
	if (![otherBranch isKindOfClass:self.class]) return NO;

	return [self.name isEqual:otherBranch.name] && [self.sha isEqual:otherBranch.sha];
}

- (NSUInteger)hash {
	return self.name.hash ^ self.sha.hash;
}


#pragma mark API

@synthesize reference;
@synthesize repository;

+ (NSString *)localNamePrefix {
	return @"refs/heads/";
}

+ (NSString *)remoteNamePrefix {
	return @"refs/remotes/";
}

+ (id)branchWithName:(NSString *)branchName repository:(GTRepository *)repo error:(NSError **)error {	
	return [[self alloc] initWithName:branchName repository:repo error:error];
}

+ (id)branchWithReference:(GTReference *)ref repository:(GTRepository *)repo {
	return [[self alloc] initWithReference:ref repository:repo];
}

- (id)initWithName:(NSString *)branchName repository:(GTRepository *)repo error:(NSError **)error {
	if((self = [super init])) {
		self.reference = [GTReference referenceByLookingUpReferencedNamed:branchName inRepository:repo error:error];
		if(self.reference == nil) {
            return nil;
        }
		
		self.repository = repo;
	}
	return self;
}

- (id)initWithReference:(GTReference *)ref repository:(GTRepository *)repo {
	if((self = [super init])) {
		self.reference = ref;
		self.repository = repo;
	}
	return self;
}

- (NSString *)name {
	return self.reference.name;
}

- (NSString *)shortName {
	if (![self.reference isValid]) return nil;

	const char *name;
	int gitError = git_branch_name(&name, self.reference.git_reference);
	if (gitError != GIT_OK) return nil;

	if (self.branchType == GTBranchTypeRemote) {
		// Skip the initial remote name and forward slash.
		name = strchr(name, '/');
		if (name == NULL) return nil;

		name++;
	}

	return @(name);
}

- (NSString *)sha {
	return self.reference.target;
}

- (NSString *)remoteName {
	if (self.branchType == GTBranchTypeLocal || ![self.reference isValid]) return nil;

	const char *name;
	int gitError = git_branch_name(&name, self.reference.git_reference);
	if (gitError != GIT_OK) return nil;

	// Find out where the remote name ends.
	const char *end = strchr(name, '/');
	if (end == NULL || end == name) return nil;

	return [[NSString alloc] initWithBytes:name length:end - name encoding:NSUTF8StringEncoding];
}

- (GTCommit *)targetCommitAndReturnError:(NSError **)error {
	if (self.sha == nil) {
		if (error != NULL) *error = GTReference.invalidReferenceError;
		return nil;
	}

	return (GTCommit *)[self.repository lookupObjectBySha:self.sha objectType:GTObjectTypeCommit error:error];
}

- (NSUInteger)numberOfCommitsWithError:(NSError **)error {
	GTEnumerator *enumerator = [[GTEnumerator alloc] initWithRepository:repository error:error];
	if (enumerator == nil) return NSNotFound;

	if (![enumerator pushSHA:self.sha error:error]) return NSNotFound;
	return [enumerator countRemainingObjects:error];
}

- (GTBranchType)branchType {
	if (self.reference.remote) {
		return GTBranchTypeRemote;
	} else {
		return GTBranchTypeLocal;
	}
}

- (NSArray *)uniqueCommitsRelativeToBranch:(GTBranch *)otherBranch error:(NSError **)error {
	NSParameterAssert(otherBranch != nil);
	
	GTCommit *mergeBase = [self.repository mergeBaseBetweenFirstOID:self.reference.OID secondOID:otherBranch.reference.OID error:error];
	if (mergeBase == nil) return nil;
	
	GTEnumerator *enumerator = [[GTEnumerator alloc] initWithRepository:self.repository error:error];
	if (enumerator == nil) return nil;
	
	[enumerator resetWithOptions:GTEnumeratorOptionsTimeSort];
	
	BOOL success = [enumerator pushSHA:self.sha error:error];
	if (!success) return nil;

	success = [enumerator hideSHA:mergeBase.sha error:error];
	if (!success) return nil;

	return [enumerator allObjectsWithError:error];
}

- (BOOL)deleteWithError:(NSError **)error {
	if (!self.reference.valid) {
		if (error != NULL) *error = GTReference.invalidReferenceError;
		return NO;
	}

	int gitError = git_branch_delete(self.reference.git_reference);
	if(gitError != GIT_OK) {
		if(error != NULL) *error = [NSError git_errorFor:gitError withAdditionalDescription:@"Failed to delete branch."];
		return NO;
	}
	
	self.reference = nil;
	
	return YES;
}

- (GTBranch *)trackingBranchWithError:(NSError **)error success:(BOOL *)success {
	if (self.branchType == GTBranchTypeRemote) {
		if (success != NULL) *success = YES;
		return self;
	}

	if (!self.reference.valid) {
		if (success != NULL) *success = NO;
		if (error != NULL) *error = GTReference.invalidReferenceError;
		return NO;
	}

	git_reference *trackingRef = NULL;
	int gitError = git_branch_upstream(&trackingRef, self.reference.git_reference);

	// GIT_ENOTFOUND means no tracking branch found.
	if (gitError == GIT_ENOTFOUND) {
		if (success != NULL) *success = YES;
		return nil;
	}

	if (gitError != GIT_OK) {
		if (success != NULL) *success = NO;
		if (error != NULL) *error = [NSError git_errorFor:gitError withAdditionalDescription:[NSString stringWithFormat:@"Failed to create reference to tracking branch from %@", self]];
		return nil;
	}

	if (trackingRef == NULL) {
		if (success != NULL) *success = NO;
		if (error != NULL) *error = [NSError git_errorFor:gitError withAdditionalDescription:[NSString stringWithFormat:@"Got a NULL remote ref for %@", self]];
		return nil;
	}

	if (success != NULL) *success = YES;

	return [[self class] branchWithReference:[[GTReference alloc] initWithGitReference:trackingRef repository:self.repository] repository:self.repository];
}

- (BOOL)calculateAhead:(size_t *)ahead behind:(size_t *)behind relativeTo:(GTBranch *)branch error:(NSError **)error {
	if (branch == nil) {
		*ahead = 0;
		*behind = 0;
		return YES;
	}

	int errorCode = git_graph_ahead_behind(ahead, behind, self.repository.git_repository, branch.reference.git_oid, self.reference.git_oid);
	if (errorCode != GIT_OK && error != NULL) {
		*error = [NSError git_errorFor:errorCode withAdditionalDescription:[NSString stringWithFormat:@"Calculating ahead/behind with %@ to %@", self, branch]];
		return NO;
	}

	return YES;
}

@end
